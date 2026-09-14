// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (kotlin/src/Sekreto.kt)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// sekreto: one interface for secrets, wherever they live.
//
// A Sekreto is an ordered chain of providers. `get` asks each in turn and
// returns the first hit, so an app can be configured from environment
// variables in development and a vault in production without changing a
// line of its own code.
//
// THE CORE IMPORTS NO PLUGIN, IN ANY FORM. The four built-in kinds -
// env, memory, dotenv, file - read at most a local file; every other
// kind is a voxgig/plugin definition under `plugins/`, and a chain may
// name one only if the calling project handed it in through `plugins`.
// That is what keeps an SDK whose chain is `[dotenv, env]` from carrying
// AWS request signing and seven HTTP vault clients. Nothing in this
// package names `KOTLINPACKAGE.feature.secrets.sekreto.plugins`, and `make check-core`
// proves it of the compiled artifact rather than of the source.
// See docs/design/plugin-providers.md.
//
// A port of typescript/src/Sekreto.ts, which is canonical.

package KOTLINPACKAGE.feature.secrets.sekreto

import KOTLINPACKAGE.feature.secrets.plugin.Catalog
import KOTLINPACKAGE.feature.secrets.plugin.Host
import KOTLINPACKAGE.feature.secrets.plugin.Plugin
import KOTLINPACKAGE.feature.secrets.plugin.PluginError

/** A secret name: dot-separated lowercase segments, e.g. `api.token`. */
typealias Name = String

/**
 * Anything sekreto refuses to do: a bad name, a missing secret, a provider
 * that could not be reached.
 */
class SekretoError(message: String) : RuntimeException(message)

private val NAMEPART = Regex("^[a-z0-9_]+$")

/** Is this a well-formed secret name? */
fun validname(name: Any?): Boolean {
    if (name !is String || name.isEmpty()) {
        return false
    }

    return name.split(".").all { NAMEPART.matches(it) }
}

/** The name, or a SekretoError. Every entry point checks its name here. */
fun checkname(name: Any?): Name {
    if (!validname(name)) {
        throw SekretoError("sekreto: invalid name: " + (name ?: ""))
    }

    return name as String
}

/** The environment-variable key for a name: `api.token` -> `API_TOKEN`. */
fun envkey(name: Any?, prefix: String? = null): String =
    (prefix ?: "") + checkname(name).split(".").joinToString("_").uppercase()

/** Where a name lives in a KV vault. */
data class VaultRef(val path: String, val field: String)

/**
 * Where a name lives in a KV vault: `api.token` -> `api` / `token`.
 *
 * A single-segment name has no path of its own, so it becomes a secret of
 * that name with the conventional field `value`.
 */
fun vaultref(name: Any?): VaultRef {
    val parts = checkname(name).split(".")

    if (1 == parts.size) {
        return VaultRef(parts[0], "value")
    }

    return VaultRef(parts.dropLast(1).joinToString("/"), parts.last())
}

/**
 * A name flattened to one segment: `api.token` -> `api_token` (GCP Secret
 * Manager, `_`) or `api-token` (Azure Key Vault, `-`).
 *
 * Those stores have no path hierarchy and reject dots in ids, so the dots
 * become the store's conventional separator. With `-` as the separator,
 * underscores flatten too: Azure Key Vault's alphabet is letters, digits
 * and hyphens only, and a valid sekreto name like `with_underscore` must
 * still be representable there. (The resulting `.`/`_` collision mirrors
 * the documented envkey behaviour, where both already map to `_`.)
 */
fun flatname(name: Any?, sep: String): String {
    val flat = checkname(name).split(".").joinToString(sep)
    return if ("-" == sep) flat.replace("_", "-") else flat
}

/**
 * The AWS SSM Parameter Store name for a name: dots become the path
 * hierarchy, rooted at `/` (or at a prefix): `db.pass.main` ->
 * `/db/pass/main`, or `/app/db/pass/main` under prefix `/app`.
 */
fun awsparam(name: Any?, prefix: String? = null): String {
    val checked = checkname(name)

    var base = prefix ?: ""
    if (base.isNotEmpty() && !base.startsWith("/")) {
        base = "/$base"
    }
    base = base.removeSuffix("/")

    return base + "/" + checked.split(".").joinToString("/")
}

/**
 * Parse `.env` text into a map of raw keys to values.
 *
 * Deliberately small: `KEY=value`, optional `export`, `#` comments on their
 * own line, and single- or double-quoted values (double quotes also
 * unescape `\n`, `\r`, `\t` and `\\`). A line with no `=` is skipped.
 */
fun parsedotenv(text: Any?): Map<String, String> {
    val out = LinkedHashMap<String, String>()

    if (text !is String) {
        return out
    }

    for (rawline in text.split("\n")) {
        val line = rawline.removeSuffix("\r").trim()

        if (line.isEmpty() || line.startsWith("#")) {
            continue
        }

        val body = if (line.startsWith("export ")) line.substring(7).trim() else line

        val eq = body.indexOf('=')
        if (0 >= eq) {
            continue
        }

        val key = body.substring(0, eq).trim()
        var value = body.substring(eq + 1).trim()

        if (2 <= value.length && value.startsWith("\"") && value.endsWith("\"")) {
            value = unescape(value.substring(1, value.length - 1))
        } else if (2 <= value.length && value.startsWith("'") && value.endsWith("'")) {
            value = value.substring(1, value.length - 1)
        }

        out[key] = value
    }

    return out
}

private fun unescape(text: String): String {
    val out = StringBuilder()
    var index = 0

    while (index < text.length) {
        if ('\\' == text[index] && index + 1 < text.length) {
            val next = text[index + 1]
            index += 2
            when (next) {
                'n' -> out.append('\n')
                'r' -> out.append('\r')
                't' -> out.append('\t')
                '\\' -> out.append('\\')
                '"' -> out.append('"')
                else -> out.append('\\').append(next)
            }
        } else {
            out.append(text[index])
            index++
        }
    }

    return out.toString()
}

/**
 * Replace known secret values in text with `[redacted]`.
 *
 * Only values of four characters or more are replaced: shorter ones are too
 * likely to appear in ordinary text, and redacting them would make logs
 * unreadable without making them safer.
 */
fun redact(text: Any?, values: List<Any?>?): String {
    var out = if (text is String) text else ""

    // sortedByDescending returns a new list: `values` belongs to the caller
    // (it is `seen` when called through Sekreto.redact), and sorting in
    // place would reorder it.
    val usable = (values ?: emptyList())
        .filterIsInstance<String>()
        .filter { 4 <= it.length }
        .sortedByDescending { it.length }

    for (value in usable) {
        out = out.replace(value, "[redacted]")
    }

    return out
}

/**
 * The store name a provider answers to when nothing says otherwise.
 *
 * `describe()` opens with the provider's kind - `hashicorp:...`,
 * `dotenv:...`, plain `env` - so the kind is the natural default, and a
 * custom provider gets a sensible name without implementing anything extra.
 */
fun storename(provider: Provider): String = provider.describe().substringBefore(':')

/**
 * The message for a kind the catalog does not hold.
 *
 * A kind sekreto has never heard of is a typo; a kind that exists as a
 * plugin but was not passed in is the split working as designed, and the
 * message names the fix. Collapsing the two was the first thing that made
 * the split confusing to use.
 */
private fun unknownkind(kind: String, catalog: Catalog): String =
    "sekreto: unknown provider kind: $kind" +
        " (available: ${catalog.names().joinToString(", ")})" +
        if (KINDS.plugin.contains(kind)) {
            " - $kind is a sekreto plugin, not built in: pass it in the plugins option"
        } else {
            ""
        }

/**
 * A SekretoError that crossed the plugin boundary comes back out as
 * itself, byte for byte. Anything else is not sekreto's to rewrite, and
 * surfaces as the host reports it, naming the instance.
 */
private fun unwrap(err: RuntimeException): RuntimeException {
    if (err is PluginError && ERROR_CODE == err.code) {
        val cause = err.details["cause"]
        if (cause is String) {
            return SekretoError(cause)
        }
    }

    return err
}

/**
 * The secrets facade: a chain of providers plus a cache.
 *
 * Two ways to read. `get` is transparent - it walks the chain and takes the
 * first hit, and the caller never learns which store answered. `getfrom` is
 * directed - it names the store, and only that store is asked. Use the
 * first for ordinary configuration, the second when *which* store holds a
 * secret is part of what you mean.
 *
 * `providers` is the chain in resolution order. An entry is a declarative
 * `ProviderSpec` - which becomes a voxgig/plugin instance on `host` - or a
 * live `Provider` of your own, which does not.
 *
 * `plugins` is the provider kinds beyond the four built-in ones that
 * `providers` may name. Static and explicit: the calling project imports
 * the definitions it needs and passes them here, and a kind it did not
 * pass is unknown to this Sekreto. A list handed to a constructor cannot
 * be erased by a compiler, which a registry filled at import can.
 *
 * `names` gives the store names of the LIVE providers, positionally; an
 * entry left null or empty falls back to the provider's kind. A spec'd
 * provider carries its own `name`.
 */
class Sekreto @JvmOverloads constructor(
    providers: List<Any?> = emptyList(),
    plugins: List<Definition> = emptyList(),
    names: List<String?> = emptyList(),
    private val docache: Boolean = true,
) {

    /**
     * The definitions this Sekreto can build: the built-ins first, then
     * what `plugins` handed in. A plugin naming a built-in kind replaces
     * it - a host substituting an implementation, never an accident,
     * because the four names are documented.
     */
    val catalog: Catalog = Plugin.makeCatalog(BUILTINS + plugins)

    /**
     * The voxgig/plugin host every spec'd provider is an instance of.
     * Read it for introspection - `host.list()` names each store's ref
     * and status - and nothing on it advances the chain.
     */
    val host: Host = Plugin.makeHost(mapOf("catalog" to catalog))

    /** One provider in the chain, under the store name it answers to. */
    private data class Entry(val store: String, val ref: String, val provider: Provider)

    /** One resolved value, with the store it came from. */
    private data class Cached(val store: String, val name: Name, val value: String)

    private var entries: List<Entry> = providers.mapIndexed { index, given ->
        when (given) {
            is ProviderSpec -> declare(given)

            is Provider -> {
                val name = names.getOrNull(index)
                Entry(if (name.isNullOrEmpty()) storename(given) else name, "", given)
            }

            else -> throw SekretoError(
                "sekreto: not a provider or a provider spec: " + (given ?: ""),
            )
        }
    }

    // A list, not a map: the store a value came from stays attached, and
    // redaction order does not vary between runs.
    private val cache = mutableListOf<Cached>()

    // Every value ever resolved, for redact(). Kept independently of the
    // read cache so that redaction still works when cache is off - otherwise
    // an uncached Sekreto would silently disable redact() and leak secrets
    // to logs.
    private val seen = mutableListOf<String>()

    /**
     * One chain entry, as a plugin instance.
     *
     * The instance is `kind` for a store named after its kind and
     * `kind$store` otherwise - `hashicorp$prod` and `hashicorp$test`
     * coexist - so `host.list()` reads like the chain. A ref that is
     * already taken gets a numbered tag from the host instead, because
     * two providers MAY share a store name (the spec says a directed read
     * walks both) and an instance ref may not: the repeat keeps its store
     * name and takes `memory$1`.
     */
    private fun declare(spec: ProviderSpec): Entry {
        val kind = spec.kind

        if (!catalog.has(kind)) {
            throw SekretoError(unknownkind(kind, catalog))
        }

        val store = if (spec.name.isNullOrEmpty()) kind else spec.name

        if (!Plugin.checkTag(store)) {
            throw SekretoError("sekreto: invalid store name: $store")
        }

        val wanted = if (store == kind) kind else Plugin.formatRef(kind, store)
        val taken = null != host.instance(wanted)

        val declaration = LinkedHashMap<String, Any?>()
        // plugin's own auto-tagging: the lowest unused positive integer,
        // assigned by the host, so nothing here counts instances.
        if (taken) {
            declaration["tag"] = "?"
        }
        declaration["options"] = optionsof(spec)

        // `load` runs the definition's `define`, which builds the provider
        // from the spec; `activate` takes the instance live. Nothing is
        // contacted by either: a provider opens nothing until its first
        // lookup.
        val ref = try {
            val loaded = host.load(if (taken) kind else wanted, declaration)
            host.activate(loaded.ref)
            loaded.ref
        } catch (err: RuntimeException) {
            throw unwrap(err)
        }

        val exported = host.exports("$ref/$PROVIDER_EXPORT")

        // A definition whose `define` exported no provider - one that is
        // not a `providerplugin` at all. plugin runs a `define` that is not
        // a function silently, so without this the chain would carry a hole.
        if (exported !is Provider) {
            throw SekretoError("sekreto: plugin $kind exported no provider")
        }

        return Entry(store, ref, exported)
    }

    /** The secret, or a SekretoError if no provider has it. */
    fun get(name: Name): String =
        tryget(name) ?: throw SekretoError("sekreto: unknown secret: $name")

    /**
     * The secret, or null if no provider has it. Named `tryget` because
     * `try` is a Kotlin keyword.
     */
    fun tryget(name: Name): String? = resolve("", name, entries)

    /** Canonical's own name for `tryget`, for callers translating from it. */
    fun `try`(name: Name): String? = tryget(name)

    /**
     * The secret from one named store, or a SekretoError if that store does
     * not have it.
     */
    fun getfrom(store: String, name: Name): String =
        tryfrom(store, name) ?: throw SekretoError("sekreto: unknown secret: $store:$name")

    /**
     * The secret from one named store, or null if that store does not have
     * it.
     *
     * Naming a store that is not in the chain is an error, not a miss:
     * `tryget` already means "this store may not have it", so it cannot also
     * mean "this store may not exist" without hiding a typo.
     */
    fun tryfrom(store: String, name: Name): String? {
        val matching = entries.filter { store == it.store }

        if (matching.isEmpty()) {
            throw SekretoError("sekreto: unknown store: $store")
        }

        return resolve(store, name, matching)
    }

    private fun resolve(store: String, name: Name, useentries: List<Entry>): String? {
        checkname(name)

        if (docache) {
            val hit = cache.find { store == it.store && name == it.name }
            if (null != hit) {
                return hit.value
            }
        }

        for (entry in useentries) {
            val found = entry.provider.lookup(name)

            if (null != found) {
                if (docache) {
                    cache.add(Cached(store, name, found))
                }
                seen.add(found)
                return found
            }
        }

        return null
    }

    /** Does any provider have this secret? */
    fun has(name: Name): Boolean = null != tryget(name)

    /** Does this named store have this secret? */
    fun hasin(store: String, name: Name): Boolean = null != tryfrom(store, name)

    /** Every named secret at once. Missing ones are an error. */
    fun all(names: List<Name>): Map<String, String> {
        val out = LinkedHashMap<String, String>()

        for (name in names) {
            out[name] = get(name)
        }

        return out
    }

    /**
     * What a Sekreto shows of itself when something prints it: its store
     * names, and nothing else.
     *
     * `println(secrets)` reaches `cache` and `seen`, which between them
     * hold every value this chain has ever resolved, so one ordinary
     * logging call would write every secret to the log. A data class would
     * do exactly that; this is why Sekreto is not one.
     */
    override fun toString(): String = "Sekreto(stores=[${stores().joinToString(", ")}])"

    /** A description of each provider, in resolution order. */
    fun sources(): List<String> = entries.map { it.provider.describe() }

    /**
     * The name of each store that can be named by `getfrom`, in resolution
     * order and without repeats.
     */
    fun stores(): List<String> = entries.map { it.store }.distinct()

    /**
     * Replace every value this Sekreto has resolved with `[redacted]`.
     *
     * Works whether or not caching is enabled: the redaction list is kept
     * independently of the read cache.
     */
    fun redact(text: String): String = redact(text, seen)

    /** Drop cached values, so the next `get` asks the providers again. */
    fun refresh() {
        cache.clear()
    }

    /**
     * Tear the chain down: every plugin instance is deactivated and
     * unloaded, in reverse, releasing whatever a provider acquired at
     * activation. Afterwards there is nothing to read from - `get` reports
     * every secret unknown - and the cache is dropped, though `redact`
     * still knows every value that was ever resolved.
     */
    fun close() {
        host.close()
        entries = emptyList()
        cache.clear()
    }
}

/**
 * Make a Sekreto from declarative provider specs - the same shape the
 * shared spec and an app's config file use.
 *
 * `plugins` is the kinds beyond the four built-in ones that `specs` may
 * name: `sekreto(chain, Plugins.ALL)` for the lot, `sekreto(chain,
 * listOf(hashicorp))` for one.
 */
@JvmOverloads
fun sekreto(
    specs: List<ProviderSpec>,
    plugins: List<Definition> = emptyList(),
    cache: Boolean = true,
): Sekreto = Sekreto(providers = specs, plugins = plugins, docache = cache)
