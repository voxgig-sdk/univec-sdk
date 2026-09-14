// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (java/src/com/voxgig/sekreto/Sekreto.java)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// sekreto: one interface for secrets, wherever they live.
//
// A Sekreto is an ordered chain of providers. `get` asks each in turn and
// returns the first hit, so an app can be configured from environment
// variables in development and a vault in production without changing a
// line of its own code.
//
// A port of typescript/src/Sekreto.ts, which is canonical.
//
// THE CORE IMPORTS NO PROVIDER THAT OPENS A SOCKET, SPAWNS A PROCESS OR
// SIGNS A REQUEST. The four built-in kinds - env, memory, dotenv, file -
// read at most a local file; every other kind is a voxgig/plugin
// definition under plugins/, and a chain may name one only if the
// calling project handed it in through Options.plugins. That is what
// keeps an SDK whose chain is [dotenv, env] from carrying AWS request
// signing and seven HTTP vault clients.
//
// The boundary here is javac's: plugins/ is a source root of its own and
// is on neither the sourcepath nor the classpath of the core's compile,
// so an import of a plugin from this package does not compile. `make
// check-core` reads the compiled core back with jdeps and says so.
// See docs/design/plugin-providers.md.

package JAVAPACKAGE.feature.secrets.sekreto;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Pattern;
import JAVAPACKAGE.feature.secrets.plugin.Catalog;
import JAVAPACKAGE.feature.secrets.plugin.Definition;
import JAVAPACKAGE.feature.secrets.plugin.Host;
import JAVAPACKAGE.feature.secrets.plugin.Plugin;
import JAVAPACKAGE.feature.secrets.plugin.PluginException;

public final class Sekreto {

  /**
   * Anything sekreto refuses to do: a bad name, a missing secret, a
   * provider that could not be reached.
   */
  public static class SekretoError extends RuntimeException {
    private static final long serialVersionUID = 1L;

    public SekretoError(String message) {
      super(message);
    }
  }

  private static final Pattern NAMEPART = Pattern.compile("^[a-z0-9_]+$");

  /**
   * One provider in the chain, under the store name it answers to, and
   * the ref of the plugin instance that built it - empty for a live
   * provider handed in directly, which no instance backs.
   */
  private static final class Entry {
    final String store;
    final String ref;
    final Provider provider;

    Entry(String store, String ref, Provider provider) {
      this.store = store;
      this.ref = ref;
      this.provider = provider;
    }
  }

  /** One resolved value, with the store it came from. */
  private static final class Cached {
    final String store;
    final String name;
    final String value;

    Cached(String store, String name, String value) {
      this.store = store;
      this.name = name;
      this.value = value;
    }
  }

  /**
   * How a Sekreto is configured. Fluent because java has no object
   * literal, and every field is optional:
   *
   * <pre>
   *   new Sekreto(new Sekreto.Options()
   *       .plugins(List.of(Hashicorp.PLUGIN))
   *       .providers(List.of(
   *           Map.of("kind", "env"),
   *           Map.of("kind", "hashicorp", "name", "prod", "addr", addr))));
   * </pre>
   */
  public static final class Options {
    private final List<Object> providers = new ArrayList<>();
    private final List<Definition> plugins = new ArrayList<>();
    private boolean cache = true;

    /**
     * The provider chain, in resolution order. An entry is a live
     * Provider, or the declarative spec of one - a map with a `kind`.
     */
    @SuppressWarnings("unchecked")
    public Options providers(Object specs) {
      if (specs instanceof List) {
        providers.addAll((List<Object>) specs);
      } else if (null != specs) {
        providers.add(specs);
      }
      return this;
    }

    /**
     * The provider kinds beyond the built-ins that `providers` may name,
     * as voxgig/plugin definitions. Static and explicit: the calling
     * project imports the plugins it needs and passes them here, and a
     * kind it did not pass is unknown to this Sekreto.
     */
    public Options plugins(List<Definition> defs) {
      if (null != defs) {
        plugins.addAll(defs);
      }
      return this;
    }

    /** Cache resolved values (default: true). */
    public Options cache(boolean on) {
      this.cache = on;
      return this;
    }
  }

  private final List<Entry> entries = new ArrayList<>();
  private final boolean docache;

  /**
   * The voxgig/plugin host every spec'd provider is an instance of. Read
   * it for introspection - `host().list()` names each store's ref and
   * status - and nothing on it advances the chain.
   */
  private final Host host;

  /** The definitions this Sekreto can build: the built-ins plus plugins. */
  private final Catalog catalog;

  // A list, not a map: the store a value came from stays attached, and
  // redaction order does not vary between runs.
  private final List<Cached> cache = new ArrayList<>();

  // Every value ever resolved, for redact(). Kept independently of the
  // read cache so that redaction still works when cache is off - otherwise
  // an uncached Sekreto would silently disable redact() and leak secrets
  // to logs.
  private final List<String> seen = new ArrayList<>();

  /** A Sekreto with no providers: every secret is unknown. */
  public Sekreto() {
    this(new Options());
  }

  public Sekreto(Options options) {
    Options opts = null == options ? new Options() : options;

    // Built-ins first, then the plugins, into one catalog: a plugin that
    // names a built-in kind replaces it, which is how a host substitutes
    // an implementation and never an accident, because the four names
    // are documented.
    List<Definition> defs = new ArrayList<>(Builtins.BUILTINS);
    for (Definition def : opts.plugins) {
      if (null == def) {
        throw new SekretoError(
            "sekreto: not a plugin definition: null"
                + " - a plugin is what Support.providerplugin(kind, make) returns");
      }
      defs.add(def);
    }

    this.catalog = Plugin.makeCatalog(defs);
    this.host = Plugin.makeHost(null);
    this.host.catalog(this.catalog);

    for (Object entry : opts.providers) {
      if (entry instanceof Provider) {
        Provider provider = (Provider) entry;
        entries.add(new Entry(storename(provider), "", provider));
      } else if (entry instanceof Map) {
        entries.add(declare(Support.map(entry)));
      } else {
        // REFUSED, NOT SKIPPED. Without this branch the loop dropped an
        // entry that was neither, silently: the chain came up one store
        // short and nothing said why, which is worse than the scala port's
        // raw MatchError because there is no error at all to read. Wording
        // is kotlin's, byte for byte.
        throw new SekretoError(
            "sekreto: not a provider or a provider spec: "
                + (null == entry ? "" : entry));
      }
    }

    this.docache = opts.cache;
  }

  /**
   * One chain entry, as a plugin instance.
   *
   * <p>The instance is `kind` for a store named after its kind and
   * `kind$store` otherwise - `hashicorp$prod` - so `host().list()` reads
   * like the chain. A store name that is already taken gets a numbered
   * tag from the host instead, because two providers MAY share a store
   * name (a directed read walks both) and an instance ref may not.
   */
  private Entry declare(Map<String, Object> spec) {
    String kind = Support.text(null == spec ? null : spec.get("kind"));

    if (null == kind || !catalog.has(kind)) {
      throw new SekretoError(unknownkind(kind));
    }

    String named = Support.text(spec.get("name"));
    String store = null == named || named.isEmpty() ? kind : named;

    if (!Plugin.checkTag(store)) {
      throw new SekretoError("sekreto: invalid store name: " + store);
    }

    String ref = store.equals(kind) ? kind : Plugin.formatRef(kind, store);

    Map<String, Object> declared = new LinkedHashMap<>();
    declared.put("options", spec);
    if (null != host.instance(ref)) {
      // The host assigns the lowest unused integer tag; the STORE name is
      // untouched, so a directed read still walks both.
      declared.put("tag", "?");
    }

    JAVAPACKAGE.feature.secrets.plugin.Entry inst;
    try {
      // `load` runs the definition's `define`, which builds the provider
      // from the spec; `activate` takes the instance live. Nothing is
      // contacted by either: a provider opens nothing until its first
      // lookup.
      inst = host.load(ref, declared);
      host.activate(inst.ref);
    } catch (RuntimeException err) {
      throw unwrap(err);
    }

    Object exported = host.exports(inst.ref + "/" + Support.PROVIDER_EXPORT);

    if (!(exported instanceof Provider)) {
      throw new SekretoError(
          "sekreto: not a provider plugin: " + kind
              + " - it exported no provider: build it with"
              + " Support.providerplugin(kind, make)");
    }

    return new Entry(store, inst.ref, (Provider) exported);
  }

  /**
   * The message for a kind the catalog does not hold.
   *
   * <p>A kind sekreto has never heard of is a typo; a kind that exists as
   * a plugin but was not passed in is the split working as designed and
   * telling you what to pass. Collapsing the two was the first thing that
   * made the split confusing to use.
   */
  private String unknownkind(String kind) {
    boolean known = Builtins.PLUGIN_KINDS.contains(kind);

    return "sekreto: unknown provider kind: " + (null == kind ? "" : kind)
        + " (available: " + String.join(", ", catalog.names()) + ")"
        + (known
            ? " - " + kind + " is a sekreto plugin, not built in: pass it in the plugins option"
            : "");
  }

  /**
   * A SekretoError that crossed the plugin boundary comes back out as
   * itself, byte for byte. Anything else is not sekreto's to rewrite and
   * surfaces as the host reports it, naming the instance.
   */
  private static RuntimeException unwrap(RuntimeException err) {
    if (err instanceof PluginException) {
      PluginException failed = (PluginException) err;
      Map<String, Object> details = Support.map(failed.details);
      Object cause = null == details ? null : details.get("cause");

      if (Support.ERROR_CODE.equals(failed.code) && cause instanceof String) {
        return new SekretoError((String) cause);
      }
    }

    return err;
  }

  /**
   * The voxgig/plugin host this chain is made of. Introspection only:
   * `host().list()` reads like the chain - the kind, or kind$store for a
   * named store - and nothing on it advances the chain.
   */
  public Host host() {
    return host;
  }

  /** The definitions this Sekreto can build: the built-ins plus plugins. */
  public Catalog catalog() {
    return catalog;
  }

  /**
   * The store name a provider answers to when nothing says otherwise.
   *
   * <p>`describe()` opens with the provider's kind - `hashicorp:...`,
   * `dotenv:...`, plain `env` - so the kind is the natural default, and a
   * custom provider gets a sensible name without implementing anything extra.
   */
  public static String storename(Provider provider) {
    return provider.describe().split(":", 2)[0];
  }

  /** Is this a well-formed secret name? */
  public static boolean validname(Object name) {
    if (!(name instanceof String) || ((String) name).isEmpty()) {
      return false;
    }

    for (String part : ((String) name).split("\\.", -1)) {
      if (!NAMEPART.matcher(part).matches()) {
        return false;
      }
    }

    return true;
  }

  public static String checkname(Object name) {
    if (!validname(name)) {
      throw new SekretoError("sekreto: invalid name: " + (null == name ? "" : name));
    }
    return (String) name;
  }

  /** The environment-variable key for a name: `api.token` -> `API_TOKEN`. */
  public static String envkey(Object name, String prefix) {
    checkname(name);

    // Locale.ROOT, not the machine's locale. `toUpperCase()` with no locale
    // uppercases `i` to `İ` (U+0130) on a Turkish or Azeri JVM, so
    // `api.token` would look for `APİ_TOKEN` - in the environment, in a
    // .env, in a secrets directory, everywhere this key is used. Every
    // lookup of every name containing an `i` would miss, silently, and the
    // chain would report the secret simply absent.
    return (null == prefix ? "" : prefix)
        + String.join("_", ((String) name).split("\\.", -1)).toUpperCase(Locale.ROOT);
  }

  /**
   * Where a name lives in a KV vault: `api.token` -> `api` / `token`.
   *
   * <p>A single-segment name has no path of its own, so it becomes a secret
   * of that name with the conventional field `value`.
   */
  public static Map<String, Object> vaultref(Object name) {
    checkname(name);

    String[] parts = ((String) name).split("\\.", -1);

    Map<String, Object> out = new LinkedHashMap<>();

    if (1 == parts.length) {
      out.put("path", parts[0]);
      out.put("field", "value");
      return out;
    }

    List<String> head = new ArrayList<>();
    for (int index = 0; index < parts.length - 1; index++) {
      head.add(parts[index]);
    }

    out.put("path", String.join("/", head));
    out.put("field", parts[parts.length - 1]);

    return out;
  }

  /**
   * A name flattened to one segment: `api.token` -> `api_token` (GCP Secret
   * Manager, `_`) or `api-token` (Azure Key Vault, `-`).
   *
   * <p>Those stores have no path hierarchy and reject dots in ids, so the
   * dots become the store's conventional separator. With `-` as the
   * separator, underscores flatten too: Azure Key Vault's alphabet is
   * letters, digits and hyphens only, and a valid sekreto name like
   * `with_underscore` must still be representable there. (The resulting
   * `.`/`_` collision mirrors the documented envkey behaviour, where both
   * already map to `_`.)
   */
  public static String flatname(Object name, String sep) {
    checkname(name);
    String flat = String.join(sep, ((String) name).split("\\.", -1));
    return "-".equals(sep) ? flat.replace("_", "-") : flat;
  }

  /**
   * The AWS SSM Parameter Store name for a name: dots become the path
   * hierarchy, rooted at `/` (or at a prefix): `db.pass.main` ->
   * `/db/pass/main`, or `/app/db/pass/main` under prefix `/app`.
   */
  public static String awsparam(Object name, String prefix) {
    checkname(name);

    String base = null == prefix ? "" : prefix;
    if (!base.isEmpty() && !base.startsWith("/")) {
      base = "/" + base;
    }
    if (base.endsWith("/")) {
      base = base.substring(0, base.length() - 1);
    }

    return base + "/" + String.join("/", ((String) name).split("\\.", -1));
  }

  /**
   * Parse `.env` text into a map of raw keys to values.
   *
   * <p>Deliberately small: `KEY=value`, optional `export`, `#` comments on
   * their own line, and single- or double-quoted values (double quotes also
   * unescape \n, \r, \t and \\). A line with no `=` is skipped.
   */
  public static Map<String, Object> parsedotenv(Object text) {
    Map<String, Object> out = new LinkedHashMap<>();

    if (!(text instanceof String)) {
      return out;
    }

    for (String rawline : ((String) text).split("\n", -1)) {
      String line = (rawline.endsWith("\r") ? rawline.substring(0, rawline.length() - 1) : rawline)
          .trim();

      if (line.isEmpty() || line.startsWith("#")) {
        continue;
      }

      String body = line.startsWith("export ") ? line.substring(7).trim() : line;

      int eq = body.indexOf('=');
      if (0 >= eq) {
        continue;
      }

      String key = body.substring(0, eq).trim();
      String value = body.substring(eq + 1).trim();

      if (2 <= value.length() && value.startsWith("\"") && value.endsWith("\"")) {
        value = unescape(value.substring(1, value.length() - 1));
      } else if (2 <= value.length() && value.startsWith("'") && value.endsWith("'")) {
        value = value.substring(1, value.length() - 1);
      }

      out.put(key, value);
    }

    return out;
  }

  static String unescape(String text) {
    StringBuilder out = new StringBuilder();

    for (int index = 0; index < text.length(); index++) {
      if ('\\' == text.charAt(index) && index + 1 < text.length()) {
        char next = text.charAt(index + 1);
        index++;
        switch (next) {
          case 'n':
            out.append('\n');
            break;
          case 'r':
            out.append('\r');
            break;
          case 't':
            out.append('\t');
            break;
          case '\\':
            out.append('\\');
            break;
          case '"':
            out.append('"');
            break;
          default:
            out.append('\\').append(next);
        }
      } else {
        out.append(text.charAt(index));
      }
    }

    return out.toString();
  }

  /**
   * Replace known secret values in text with `[redacted]`.
   *
   * <p>Only values of four characters or more are replaced: shorter ones are
   * too likely to appear in ordinary text, and redacting them would make
   * logs unreadable without making them safer.
   */
  public static String redact(Object text, List<Object> values) {
    String out = text instanceof String ? (String) text : "";

    if (null == values) {
      return out;
    }

    // Longest first: a shorter secret that prefixes a longer one used to eat
    // the prefix and leave the rest in the log. Collected into our own list,
    // so the caller's is not reordered.
    List<String> usable = new ArrayList<>();
    for (Object value : values) {
      if (value instanceof String && 4 <= ((String) value).length()) {
        usable.add((String) value);
      }
    }
    usable.sort((left, right) -> right.length() - left.length());

    for (String value : usable) {
      out = String.join("[redacted]", out.split(Pattern.quote(value), -1));
    }

    return out;
  }

  /** The secret, or a SekretoError if no provider has it. */
  public String get(String name) {
    String found = tryget(name);

    if (null == found) {
      throw new SekretoError("sekreto: unknown secret: " + name);
    }

    return found;
  }

  /**
   * The secret, or null if no provider has it. Named `tryget` because `try`
   * is a Java keyword.
   */
  public String tryget(String name) {
    return resolve("", name, entries);
  }

  /**
   * The secret from one named store, or a SekretoError if that store does not
   * have it.
   */
  public String getfrom(String store, String name) {
    String found = tryfrom(store, name);

    if (null == found) {
      throw new SekretoError("sekreto: unknown secret: " + store + ":" + name);
    }

    return found;
  }

  /**
   * The secret from one named store, or null if that store does not have it.
   *
   * <p>Naming a store that is not in the chain is an error, not a miss:
   * `tryget` already means "this store may not have it", so it cannot also
   * mean "this store may not exist" without hiding a typo.
   */
  public String tryfrom(String store, String name) {
    List<Entry> matching = new ArrayList<>();

    for (Entry entry : entries) {
      if (entry.store.equals(store)) {
        matching.add(entry);
      }
    }

    if (matching.isEmpty()) {
      throw new SekretoError("sekreto: unknown store: " + store);
    }

    return resolve(store, name, matching);
  }

  private String resolve(String store, String name, List<Entry> useentries) {
    checkname(name);

    if (docache) {
      for (Cached hit : cache) {
        if (hit.store.equals(store) && hit.name.equals(name)) {
          return hit.value;
        }
      }
    }

    for (Entry entry : useentries) {
      String found = entry.provider.lookup(name);

      if (null != found) {
        if (docache) {
          cache.add(new Cached(store, name, found));
        }
        seen.add(found);
        return found;
      }
    }

    return null;
  }

  /** Does any provider have this secret? */
  public boolean has(String name) {
    return null != tryget(name);
  }

  /** Does this named store have this secret? */
  public boolean hasin(String store, String name) {
    return null != tryfrom(store, name);
  }

  /** Every named secret at once. Missing ones are an error. */
  public Map<String, String> all(List<String> names) {
    Map<String, String> out = new LinkedHashMap<>();

    for (String name : names) {
      out.put(name, get(name));
    }

    return out;
  }

  /** A description of each provider, in resolution order. */
  public List<Object> sources() {
    List<Object> out = new ArrayList<>();

    for (Entry entry : entries) {
      out.add(entry.provider.describe());
    }

    return out;
  }

  /**
   * The name of each store that can be named by `getfrom`, in resolution
   * order and without repeats.
   */
  public List<Object> stores() {
    List<Object> out = new ArrayList<>();

    for (Entry entry : entries) {
      if (!out.contains(entry.store)) {
        out.add(entry.store);
      }
    }

    return out;
  }

  /**
   * Replace every value this Sekreto has resolved with `[redacted]`.
   *
   * <p>Works whether or not caching is enabled: the redaction list is kept
   * independently of the read cache.
   */
  public String redact(String text) {
    List<Object> values = new ArrayList<>(seen);
    return redact(text, values);
  }

  /** Drop cached values, so the next `get` asks the providers again. */
  public void refresh() {
    cache.clear();
  }

  /**
   * Tear the chain down: every plugin instance is deactivated and
   * unloaded, in reverse, releasing whatever a provider acquired at
   * activation. Afterwards there is nothing to read from - `get` reports
   * every secret unknown - and the cache is dropped, though `redact`
   * still knows every value that was ever resolved.
   */
  public void close() {
    host.close();
    entries.clear();
    cache.clear();
  }
}
