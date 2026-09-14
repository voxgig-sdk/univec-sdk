// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (kotlin/src/Providers.kt)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// THE BUILT-IN PROVIDER KINDS - the same four in every port.
//
// A provider answers one question: "do you have this secret?" It returns
// the value, or null to mean "ask the next one". Nothing else about a
// provider is visible to the caller - which is the point: an app reads
// `api.token` and never learns whether it came from the environment, a
// .env file or a mounted secret directory.
//
// What makes a kind built in is that it reads AT MOST A LOCAL FILE: no
// socket, no TLS, no crypto, no child process. These four are the floor
// every chain stands on, and a chain that reads secrets from options, the
// environment, a plaintext `.env` and a mounted secret directory works
// with no plugin loaded at all. Everything else - the vault clients, the
// cloud stores, the two CLIs, and `sigv4` with them - is a voxgig/plugin
// definition under `plugins/`, and this file is the reason the core links
// none of it (docs/design/plugin-providers.md).
//
// Two failure shapes, and they are never interchangeable. A store that does
// not hold the secret is a MISS (null) - the chain carries on. A store that
// could not answer - bad credentials, unreachable host, missing
// configuration - is an ERROR: falling through there would quietly reach
// for a weaker store.
//
// A port of typescript/src/provider/, which is canonical.

package KOTLINPACKAGE.feature.secrets.sekreto

import java.io.IOException
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.Paths

object Providers {

    /**
     * Does this read failure mean "no secrets here", rather than "I could not
     * answer"?
     *
     * Absence is a MISS and the chain carries on; anything else - permission
     * denied, an unreadable mount, a failing disk - is an ERROR, because
     * returning a miss there falls silently through to a weaker store.
     *
     * Asked of the directory, not of the file. The obvious spelling,
     * `!Files.exists(file)`, is wrong in exactly the case the rule exists
     * for: `Files.exists` is "did checkAccess throw", so it answers *false*
     * for an `AccessDeniedException` and turned a locked directory - the
     * canonical "unreadable mount" - into a miss. A path whose parent is a
     * plain file (ENOTDIR) really is "no secrets here", and that is what this
     * asks. The reason string is not consulted: it comes from the C library's
     * strerror and follows the machine's locale.
     */
    internal fun absent(file: Path): Boolean {
        val dir = file.parent
        return null != dir && !Files.isDirectory(dir)
    }

    /**
     * An address with any userinfo replaced by `[redacted]`, for messages.
     *
     * Every refusal below names the address it refused, and one of them fires
     * precisely because the address carries a credential - so printing it
     * verbatim wrote the password to stderr and into the logs. It cannot be
     * cleaned up afterwards either: that password was never resolved as a
     * secret, so redact() has never seen it and never will. The host is what
     * a reader needs to identify which chain entry is at fault; the userinfo
     * is not.
     */
    internal fun safeaddr(addr: String): String {
        val mark = addr.indexOf("://")
        if (-1 == mark) {
            return addr
        }

        val rest = addr.substring(mark + 3)
        val stop = rest.indexOfFirst { it in "/?#" }
        val authority = if (-1 == stop) rest else rest.substring(0, stop)

        val at = authority.lastIndexOf('@')
        if (-1 == at) {
            return addr
        }

        return addr.substring(0, mark + 3) + "[redacted]" + addr.substring(mark + 3 + at)
    }

    /**
     * Refuse to send a secret-bearing credential in the clear.
     *
     * A vault API is HTTPS in any real deployment; plaintext is a dev-mode
     * convenience. Sending a token over http to anything but the local
     * machine puts both the token and the secret it fetches on the wire for
     * anyone on the path, so sekreto will not do it. Loopback stays allowed:
     * that is `vault server -dev`, `boru vault serve`, and this repo's own
     * test harness.
     *
     * The address is read by hand, in the same handful of steps in every
     * port, rather than by each platform's URL parser. That is deliberate.
     * Twelve parsers disagree about malformed input - where userinfo ends,
     * whether `0177.0.0.1` is loopback, what an unclosed bracket means - and
     * a check that answers differently in different ports is not a check.
     *
     * The rule this parse obeys, and the reason it can be trusted: it is
     * never more permissive than the HTTP client that will dial the address.
     * It ends the authority at `/`, `?` or `#` only, so a client that also
     * breaks on `\` (WHATWG does) can only ever see a SHORTER host than this
     * does. It refuses userinfo outright rather than locating its end. It
     * compares the host literally, so a numeric form no parser here agrees
     * on is refused rather than guessed at.
     */
    fun checkaddr(addr: String) {
        val scheme = when {
            addr.startsWith("https://") -> "https://"
            addr.startsWith("http://") -> "http://"
            else -> throw SekretoError("sekreto: not an http(s) address: ${safeaddr(addr)}")
        }

        val rest = addr.substring(scheme.length)
        val end = rest.indexOfFirst { it in "/?#" }
        val authority = if (-1 == end) rest else rest.substring(0, end)

        // Userinfo is refused outright rather than parsed around, and on
        // https as well as http. No store this library speaks authenticates
        // by userinfo - they take a token or a signature - so an address
        // carrying one is a mistake at best. At worst it is the attack this
        // whole function exists to stop:
        // `http://localhost:8200@evil.example.com/` is a request to
        // evil.example.com that reads, to anything that splits the authority
        // on ':', as loopback.
        if (authority.contains("@")) {
            throw SekretoError("sekreto: refusing an address with embedded credentials: ${safeaddr(addr)}")
        }

        // An opening bracket with no closing one is not an address at all.
        if (authority.startsWith("[") && !authority.contains("]")) {
            throw SekretoError("sekreto: not a valid http(s) address: ${safeaddr(addr)}")
        }

        if ("https://" == scheme) {
            return
        }

        // A bracketed IPv6 literal keeps its brackets. Splitting the
        // authority on the first colon yields '[', so `http://[::1]:8200`
        // could never match - which made the '[::1]' entry below unreachable,
        // and refused a legitimate local vault.
        val host = (
            if (authority.startsWith("[")) {
                authority.substring(0, authority.indexOf("]") + 1)
            } else {
                authority.substringBefore(':')
            }
            ).lowercase()

        if ("localhost" == host || "127.0.0.1" == host || "::1" == host || "[::1]" == host) {
            return
        }

        throw SekretoError(
            "sekreto: refusing to send a token in plaintext to ${safeaddr(addr)} (use https)",
        )
    }

    /** Environment variables: `api.token` from `API_TOKEN`. */
    class Env(
        private val prefix: String? = null,
        private val source: Map<String, String>? = null,
    ) : Provider {

        override fun lookup(name: String): String? {
            val key = envkey(name, prefix)
            return if (null == source) System.getenv(key) else source[key]
        }

        override fun describe(): String =
            "env" + if (prefix.isNullOrEmpty()) "" else ":$prefix"
    }

    /** A `.env` file, read once, keyed exactly like the environment. */
    class Dotenv(private val file: String, private val prefix: String? = null) : Provider {

        private var values: Map<String, String>? = null

        private fun load(): Map<String, String> {
            values?.let { return it }

            val path = Paths.get(file)

            val loaded: Map<String, String> = try {
                parsedotenv(String(Files.readAllBytes(path), StandardCharsets.UTF_8))
            } catch (err: NoSuchFileException) {
                // An absent file - or an absent directory - means "no secrets
                // here", exactly like the file provider.
                emptyMap()
            } catch (err: IOException) {
                if (absent(path)) {
                    emptyMap()
                } else {
                    throw SekretoError(
                        "sekreto: dotenv provider cannot read $file: ${err.message}",
                    )
                }
            }

            values = loaded
            return loaded
        }

        override fun lookup(name: String): String? = load()[envkey(name, prefix)]

        override fun describe(): String = "dotenv:$file"
    }

    /**
     * Literal values, keyed like environment variables. The spec uses this
     * to test chain behaviour without touching the outside world.
     */
    class Memory(
        values: Map<String, String>? = null,
        private val prefix: String? = null,
    ) : Provider {

        private val values: Map<String, String> = values ?: emptyMap()

        override fun lookup(name: String): String? = values[envkey(name, prefix)]

        override fun describe(): String =
            "memory" + if (prefix.isNullOrEmpty()) "" else ":$prefix"
    }

    /**
     * A directory of one-secret-per-file entries, keyed like the
     * environment: `api.token` reads `<dir>/API_TOKEN`.
     *
     * This is the shape of a mounted Kubernetes Secret, a Docker or Swarm
     * secret, and a systemd credentials directory, so those all work with no
     * further configuration. One trailing newline is stripped - tools that
     * write these files disagree about it, and a newline is never part of a
     * secret on purpose.
     */
    class File(dir: String?, private val prefix: String? = null) : Provider {

        private val dir: String = dir ?: ""

        override fun lookup(name: String): String? {
            val file = Paths.get(dir, envkey(name, prefix))

            val text = try {
                String(Files.readAllBytes(file), StandardCharsets.UTF_8)
            } catch (err: NoSuchFileException) {
                // An absent file - or an absent directory - means "no secrets
                // here", exactly like a missing .env.
                return null
            } catch (err: IOException) {
                if (absent(file)) {
                    return null
                }
                throw SekretoError("sekreto: file provider cannot read $file: ${err.message}")
            }

            if (text.endsWith("\r\n")) {
                return text.dropLast(2)
            }
            if (text.endsWith("\n")) {
                return text.dropLast(1)
            }

            return text
        }

        override fun describe(): String = "file:$dir"
    }
}

/**
 * The four built-in kinds, as voxgig/plugin definitions.
 *
 * Every kind is made the same way, built-in or plugin, shipped or
 * custom: one `providerplugin` call. `Sekreto` puts these into its
 * catalog first, then whatever `plugins` handed in, so a plugin naming a
 * built-in kind replaces it - a host substituting an implementation,
 * never an accident, because these four names are documented.
 */
val BUILTINS: List<Definition> = listOf(
    providerplugin("env") { spec -> Providers.Env(spec.prefix) },
    providerplugin("memory") { spec -> Providers.Memory(spec.values, spec.prefix) },
    providerplugin("dotenv") { spec -> Providers.Dotenv(spec.file ?: ".env", spec.prefix) },
    providerplugin("file") { spec -> Providers.File(spec.dir ?: "", spec.prefix) },
)

/**
 * Every kind this library ships, built in or as a plugin, so that a kind
 * sekreto has never heard of can be told from one that exists as a
 * plugin and was not passed in.
 */
object KINDS {

    val builtin: List<String> = listOf("env", "memory", "dotenv", "file")

    val plugin: List<String> = listOf(
        "hashicorp", "boru", "awssecrets", "awsparams", "gcpsecrets",
        "azuresecrets", "onepassword", "doppler", "infisical", "secretspec",
    )
}
