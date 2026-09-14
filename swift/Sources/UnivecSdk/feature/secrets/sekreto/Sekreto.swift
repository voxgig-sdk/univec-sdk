// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (swift/src/Sekreto.swift)
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
// definition in the SekretoPlugins module under plugins/, and a chain may
// name one only if the calling project handed it in through `plugins`.
// That is what keeps an SDK whose chain is `[dotenv, env]` from carrying
// AWS request signing and seven HTTP vault clients. The boundary is the
// swift module: `swiftc -module-name Sekreto src/*.swift` never sees
// plugins/, and the plugins import this module rather than the other way
// round. See docs/design/plugin-providers.md.

import Foundation

import VoxgigPlugin

/// A secret name: dot-separated lowercase segments, e.g. `api.token`.
public typealias Name = String

/// Anything sekreto refuses to do: a bad name, a missing secret, a
/// provider that could not be reached.
///
/// The message is the whole contract - no code, no fields, no cause - and
/// the shared spec pins it byte for byte.
public struct SekretoError: Error, CustomStringConvertible {

  public let message: String

  public init(_ message: String) {
    self.message = message
  }

  public var description: String { return message }

  public var localizedDescription: String { return message }
}

/// Uppercase and lowercase the ASCII letters and nothing else.
///
/// `String.uppercased()` is locale-sensitive, and under a Turkish locale
/// `i` becomes `İ` - which would turn `api.token` into a key no
/// environment holds. envkey must answer the same everywhere.
public func asciiupper(_ text: String) -> String {
  var out = ""
  out.unicodeScalars.reserveCapacity(text.unicodeScalars.count)

  for ch in text.unicodeScalars {
    if 0x61 <= ch.value && 0x7a >= ch.value {
      out.unicodeScalars.append(Unicode.Scalar(ch.value - 32)!)
    } else {
      out.unicodeScalars.append(ch)
    }
  }

  return out
}

public func asciilower(_ text: String) -> String {
  var out = ""
  out.unicodeScalars.reserveCapacity(text.unicodeScalars.count)

  for ch in text.unicodeScalars {
    if 0x41 <= ch.value && 0x5a >= ch.value {
      out.unicodeScalars.append(Unicode.Scalar(ch.value + 32)!)
    } else {
      out.unicodeScalars.append(ch)
    }
  }

  return out
}

/// Drop a suffix if it is there. `.` and `_` both appear in names, so this
/// is spelled out rather than reached for through a regex.
func dropsuffix(_ text: String, _ suffix: String) -> String {
  return text.hasSuffix(suffix) ? String(text.dropLast(suffix.count)) : text
}

/// Split on the literal dot, KEEPING trailing empties, so that `a.` is two
/// segments (one of them empty) and therefore not a valid name.
func segments(_ name: String) -> [String] {
  return name.components(separatedBy: ".")
}

/// Whatever a caller passed, as the text an error message should name it
/// by. Null and absent both render as the empty string.
func nametext(_ name: Any?) -> String {
  guard let name = name else { return "" }
  if let text = name as? String { return text }
  if let flag = name as? Bool { return flag ? "true" : "false" }
  if let value = name as? Double { return numstr(value) }
  if let value = name as? Int { return String(value) }
  return String(describing: name)
}

/// Is this a well-formed secret name?
///
/// Scanned character by character rather than matched against
/// `^[a-z0-9_]+$`: in most regex dialects `$` also matches before a final
/// newline, so `api.token\n` would pass - and the spec has that exact
/// case, along with `api.token\r`.
public func validname(_ name: Any?) -> Bool {
  guard let text = name as? String, !text.isEmpty else { return false }

  for part in segments(text) {
    if part.isEmpty { return false }

    for ch in part.unicodeScalars {
      let code = ch.value
      let ok =
        (0x61 <= code && 0x7a >= code)  // a-z
        || (0x30 <= code && 0x39 >= code)  // 0-9
        || 0x5f == code  // _
      if !ok { return false }
    }
  }

  return true
}

/// The name, or a SekretoError. Every entry point checks its name here.
public func checkname(_ name: Any?) throws -> Name {
  guard validname(name), let text = name as? String else {
    throw SekretoError("sekreto: invalid name: " + nametext(name))
  }

  return text
}

/// The environment-variable key for a name: `api.token` -> `API_TOKEN`.
/// The prefix is used verbatim, and is NOT uppercased.
public func envkey(_ name: Any?, _ prefix: String? = nil) throws -> String {
  let checked = try checkname(name)
  return (prefix ?? "") + asciiupper(segments(checked).joined(separator: "_"))
}

/// Where a name lives in a KV vault.
public struct VaultRef {
  public let path: String
  public let field: String
}

/// Where a name lives in a KV vault: `api.token` -> `api` / `token`.
///
/// A single-segment name has no path of its own, so it becomes a secret of
/// that name with the conventional field `value`.
public func vaultref(_ name: Any?) throws -> VaultRef {
  let parts = segments(try checkname(name))

  if 1 == parts.count {
    return VaultRef(path: parts[0], field: "value")
  }

  return VaultRef(
    path: parts.dropLast().joined(separator: "/"),
    field: parts[parts.count - 1]
  )
}

/// A name flattened to one segment: `api.token` -> `api_token` (GCP Secret
/// Manager, `_`) or `api-token` (Azure Key Vault, `-`).
///
/// Those stores have no path hierarchy and reject dots in ids, so the dots
/// become the store's conventional separator. With `-` as the separator,
/// underscores flatten too: Azure Key Vault's alphabet is letters, digits
/// and hyphens only, and a valid sekreto name like `with_underscore` must
/// still be representable there.
public func flatname(_ name: Any?, _ sep: String) throws -> String {
  let flat = segments(try checkname(name)).joined(separator: sep)
  return "-" == sep ? flat.replacingOccurrences(of: "_", with: "-") : flat
}

/// The AWS SSM Parameter Store name for a name: dots become the path
/// hierarchy, rooted at `/` (or at a prefix): `db.pass.main` ->
/// `/db/pass/main`, or `/app/db/pass/main` under prefix `/app`.
public func awsparam(_ name: Any?, _ prefix: String? = nil) throws -> String {
  let checked = try checkname(name)

  var base = prefix ?? ""
  if !base.isEmpty && !base.hasPrefix("/") { base = "/" + base }
  base = dropsuffix(base, "/")

  return base + "/" + segments(checked).joined(separator: "/")
}

/// Parse `.env` text into a map of raw keys to values.
///
/// Deliberately small: `KEY=value`, optional `export`, `#` comments on
/// their own line, and single- or double-quoted values (double quotes also
/// unescape `\n`, `\r`, `\t`, `\\` and `\"`). A line with no `=`, or with
/// an empty key, is skipped without disturbing the lines around it.
public func parsedotenv(_ text: Any?) -> Ordered<String> {
  var out = Ordered<String>()

  guard let body = text as? String else { return out }

  // CRLF FIRST, and not by dropping a suffix afterwards: in Swift "\r\n" is a
  // single Character - one grapheme cluster - so `components(separatedBy: "\n")`
  // does not split it at all, and a CRLF file arrives as ONE line whose value
  // swallows every later key. The trailing-\r drop below only ever helped a
  // lone \r, which is why the bug survived it.
  for rawline in body.replacingOccurrences(of: "\r\n", with: "\n")
    .components(separatedBy: "\n")
  {
    let line = dropsuffix(rawline, "\r").trimmingCharacters(in: .whitespacesAndNewlines)

    if line.isEmpty || line.hasPrefix("#") { continue }

    let entry =
      line.hasPrefix("export ")
      ? String(line.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines) : line

    guard let mark = entry.firstIndex(of: "=") else { continue }

    let key = String(entry[entry.startIndex..<mark])
      .trimmingCharacters(in: .whitespacesAndNewlines)

    // Both "no =" and "empty key" are skipped, silently.
    if key.isEmpty { continue }

    var value = String(entry[entry.index(after: mark)...])
      .trimmingCharacters(in: .whitespacesAndNewlines)

    if 2 <= value.count && value.hasPrefix("\"") && value.hasSuffix("\"") {
      value = unescape(String(value.dropFirst().dropLast()))
    } else if 2 <= value.count && value.hasPrefix("'") && value.hasSuffix("'") {
      value = String(value.dropFirst().dropLast())
    }

    out[key] = value
  }

  return out
}

/// Unescape a double-quoted `.env` value. An escape this does not know is
/// preserved whole - backslash and all - rather than swallowed, and a
/// trailing backslash is literal.
func unescape(_ text: String) -> String {
  let chars = Array(text)
  var out = ""
  var index = 0

  while index < chars.count {
    if "\\" == chars[index] && index + 1 < chars.count {
      let next = chars[index + 1]
      index += 2
      switch next {
      case "n": out.append("\n")
      case "r": out.append("\r")
      case "t": out.append("\t")
      case "\\": out.append("\\")
      case "\"": out.append("\"")
      default:
        out.append("\\")
        out.append(next)
      }
    } else {
      out.append(chars[index])
      index += 1
    }
  }

  return out
}

/// Replace known secret values in text with `[redacted]`.
///
/// Only values of four characters or more are replaced: shorter ones are
/// too likely to appear in ordinary text, and redacting them would make
/// logs unreadable without making them safer.
public func redact(_ text: Any?, _ values: [Any?]?) -> String {
  var out = (text as? String) ?? ""

  // Sorted on a COPY: `values` belongs to the caller (it is `seen` when
  // called through Sekreto.redact), and sorting in place would reorder the
  // live redaction history.
  //
  // Longest first, always. A shorter value that is a prefix of a longer
  // one would otherwise redact half of it and leave the rest in the log.
  //
  // Sorted STABLY, by carrying the arrival index: Swift's `sorted` makes
  // no stability promise, and two values of the same length would
  // otherwise be redacted in an order that varies between runs.
  let usable =
    (values ?? [])
    .compactMap { $0 as? String }
    .filter { 4 <= $0.count }
    .enumerated()
    .sorted { left, right in
      if left.element.count != right.element.count {
        return left.element.count > right.element.count
      }
      return left.offset < right.offset
    }
    .map { $0.element }

  for value in usable {
    // A literal replace-all, never a regex: a secret containing regex
    // metacharacters must not be interpreted as a pattern.
    out = out.replacingOccurrences(of: value, with: "[redacted]")
  }

  return out
}

/// The store name a provider answers to when nothing says otherwise.
///
/// `describe()` opens with the provider's kind - `hashicorp:...`,
/// `dotenv:...`, plain `env` - so the kind is the natural default, and a
/// custom provider gets a sensible name without implementing anything
/// extra.
public func storename(_ provider: Provider) -> String {
  let text = provider.describe()

  if let mark = text.firstIndex(of: ":") {
    return String(text[text.startIndex..<mark])
  }

  return text
}

/// The message for a kind the catalog does not hold.
///
/// A kind sekreto has never heard of is a typo; a kind that exists as a
/// plugin but was not passed in is the split working as designed and
/// telling you what to pass. Collapsing the two was the first thing that
/// made the split confusing to use.
func unknownkind(_ kind: String, _ catalog: Catalog) -> String {
  let known = KINDS.plugin.contains(kind)

  return "sekreto: unknown provider kind: " + kind
    + " (available: " + catalog.names().joined(separator: ", ") + ")"
    + (known
      ? " - " + kind + " is a sekreto plugin, not built in: pass it in the plugins option"
      : "")
}

/// A SekretoError that crossed the plugin boundary comes back out as
/// itself, byte for byte. Anything else is not sekreto's to rewrite and
/// surfaces as the host reports it, naming the instance.
func unwrap(_ err: Error) -> Error {
  if let raised = err as? PluginError, ERROR_CODE == raised.code,
    let cause = raised.details["cause"]?.asString
  {
    return SekretoError(cause)
  }

  return err
}

/// The secrets facade: a chain of providers plus a cache.
///
/// Two ways to read. `get` is transparent - it walks the chain and takes
/// the first hit, and the caller never learns which store answered.
/// `getfrom` is directed - it names the store, and only that store is
/// asked. Use the first for ordinary configuration, the second when
/// *which* store holds a secret is part of what you mean.
///
/// A spec'd entry is a voxgig/plugin instance on `host`; a provider handed
/// in already built is not, and joins the chain as it is. `names` gives
/// the store names for that second form, positionally; an entry left nil
/// or empty falls back to the provider's kind.
public final class Sekreto: CustomStringConvertible {

  /// The voxgig/plugin host every spec'd provider is an instance of. Read
  /// it for introspection - `list()` names each store's ref and status -
  /// and nothing on it advances the chain.
  ///
  /// Qualified: Foundation ships a `Host` of its own, and an unqualified
  /// one here is ambiguous rather than wrong-and-quiet.
  public let host: VoxgigPlugin.Host

  /// The definitions this Sekreto can build: the built-ins, plus whatever
  /// `plugins` handed in.
  public let catalog: Catalog

  /// One provider in the chain, under the store name it answers to, and
  /// the ref of the plugin instance that built it - "" for a provider
  /// handed in already built, which no instance backs.
  private struct Entry {
    let store: String
    let ref: String
    let provider: Provider
  }

  /// One resolved value, with the store it came from.
  private struct Cached {
    let store: String
    let name: Name
    let value: String
  }

  private var entries: [Entry] = []

  // A list, not a dictionary: the store a value came from stays attached,
  // and redaction order does not vary between runs.
  private var cache: [Cached] = []

  // Every value ever resolved, for redact(). Kept independently of the
  // read cache so that redaction still works when caching is off -
  // otherwise an uncached Sekreto would silently disable redact() and leak
  // secrets to logs. Append-only for the object's life: neither refresh()
  // nor close() clears it.
  private var seen: [String] = []

  private let docache: Bool

  /// A chain of declarative specs, built through the plugin host.
  ///
  /// `plugins` is the load-bearing argument: this Sekreto can build the
  /// four built-in kinds and EXACTLY the definitions handed in here.
  /// Loading is explicit, never a side effect of importing - a list given
  /// to an initialiser cannot be erased by a compiler, and the set of
  /// stores an app can reach is not something to discover at run time.
  ///
  /// Eager and in chain order, so a chain that cannot be built says so at
  /// once. Construction contacts nothing: the first network call is the
  /// first lookup.
  /// ONE CHAIN, EITHER KIND OF ENTRY.
  ///
  /// A chain is ORDERED, and the two kinds interleave: the canonical
  /// TypeScript port takes a single `providers` list and dispatches per
  /// entry on whether it has a `lookup`. This port had two mutually
  /// exclusive initialisers instead, so a caller holding a live Provider
  /// (an in-memory store for an explicitly supplied credential, say) could
  /// not ALSO configure specs — which is exactly what a generated SDK
  /// needs, with the explicit credential first and the configured chain
  /// behind it. Two arrays would not do either: that loses the interleaving
  /// the order carries.
  public enum ChainItem {
    /// A provider already built. `name` overrides the store name it
    /// answers to; nil takes the name from the provider itself.
    case provider(Provider, name: String?)
    /// A provider to be built from the catalog, as `specs:` does.
    case spec(ProviderSpec)

    public static func provider(_ p: Provider) -> ChainItem {
      .provider(p, name: nil)
    }
  }

  /// The general initialiser. The two below stay as they are rather than
  /// delegating to it: `providers:` does not throw, and routing it through
  /// a throwing initialiser would change its signature for every existing
  /// caller to buy nothing.
  public init(
    chain: [ChainItem],
    plugins: [Definition] = [],
    cache docache: Bool = true
  ) throws {
    self.docache = docache

    do {
      self.catalog = try makeCatalog(BUILTINS + plugins)
    } catch {
      throw unwrap(error)
    }

    self.host = makeHost(HostOptions(catalog: self.catalog))

    for item in chain {
      switch item {
      case .spec(let spec):
        entries.append(try declare(spec))
      case .provider(let provider, let name):
        var store = name ?? ""
        if store.isEmpty { store = storename(provider) }
        entries.append(Entry(store: store, ref: "", provider: provider))
      }
    }
  }

  public init(
    specs: [ProviderSpec] = [],
    plugins: [Definition] = [],
    cache docache: Bool = true
  ) throws {
    self.docache = docache

    // Built-ins first, then the plugins, into one catalog: a plugin that
    // names a built-in kind replaces it, which is how a host substitutes
    // an implementation and never an accident, because the four names are
    // documented.
    do {
      self.catalog = try makeCatalog(BUILTINS + plugins)
    } catch {
      throw unwrap(error)
    }

    self.host = makeHost(HostOptions(catalog: self.catalog))

    for spec in specs {
      entries.append(try declare(spec))
    }
  }

  /// A chain of providers already built. They join as they are, under the
  /// store name each answers to, backed by no plugin instance - so `host`
  /// is empty and `close()` has nothing of theirs to tear down.
  public init(
    providers: [Provider],
    names: [String?] = [],
    cache docache: Bool = true
  ) {
    self.docache = docache

    // The built-ins, as in every other Sekreto: this chain cannot use them
    // - it holds providers, not specs - but `catalog` reads the same either
    // way. `makeCatalog` refuses only a malformed definition name, and
    // these four are literals, so the fallback is unreachable and there is
    // nothing here worth making this initialiser throw for.
    self.catalog = (try? makeCatalog(BUILTINS)) ?? Catalog()
    self.host = makeHost(HostOptions(catalog: self.catalog))

    for (index, provider) in providers.enumerated() {
      var store = index < names.count ? (names[index] ?? "") : ""
      if store.isEmpty { store = storename(provider) }
      entries.append(Entry(store: store, ref: "", provider: provider))
    }
  }

  /// One chain entry, as a plugin instance.
  ///
  /// The instance is `kind` for a store named after its kind and
  /// `kind$store` otherwise - `hashicorp$prod` - so `host.list()` reads
  /// like the chain. A store name that is already taken gets a numbered
  /// tag from the host instead (`tag: "?"` is the host's own request for
  /// the lowest unused one), because two providers MAY share a store name
  /// - a directed read walks both, and the spec pins it - and an instance
  /// ref may not.
  private func declare(_ spec: ProviderSpec) throws -> Entry {
    if !catalog.has(spec.kind) {
      throw SekretoError(unknownkind(spec.kind, catalog))
    }

    let store = first(spec.name, spec.kind)

    if !Refs.checkTag(.str(store)) {
      throw SekretoError("sekreto: invalid store name: \(store)")
    }

    do {
      let wanted =
        store == spec.kind ? spec.kind : try Refs.formatRef(.str(spec.kind), .str(store))

      var declaration: [String: Value] = ["options": optionsof(spec)]

      if nil != (try host.instance(.str(wanted))) {
        declaration["definition"] = .str(spec.kind)
        declaration["tag"] = .str("?")
      }

      // `load` runs the definition's `define`, which builds the provider
      // from the spec; `activate` takes the instance live. Nothing is
      // contacted by either: a provider opens nothing until its first
      // lookup.
      let loaded = try host.load(.str(wanted), .map(declaration))
      try host.activate(.str(loaded.ref))

      let exported = try host.exports(loaded.ref + "/" + PROVIDER_EXPORT)

      guard case .opaque(let held) = exported, let provider = held as? Provider else {
        throw SekretoError("sekreto: plugin \(spec.kind) exported no provider")
      }

      return Entry(store: store, ref: loaded.ref, provider: provider)
    } catch {
      throw unwrap(error)
    }
  }

  /// The secret, or a SekretoError if no provider has it.
  public func get(_ name: Name) throws -> String {
    guard let found = try tryget(name) else {
      throw SekretoError("sekreto: unknown secret: \(name)")
    }
    return found
  }

  /// The secret, or nil if no provider has it. Named `tryget` because
  /// `try` is a Swift keyword.
  public func tryget(_ name: Name) throws -> String? {
    return try resolve("", name, entries)
  }

  /// The secret from one named store, or a SekretoError if that store does
  /// not have it.
  public func getfrom(_ store: String, _ name: Name) throws -> String {
    guard let found = try tryfrom(store, name) else {
      throw SekretoError("sekreto: unknown secret: \(store):\(name)")
    }
    return found
  }

  /// The secret from one named store, or nil if that store does not have
  /// it.
  ///
  /// Naming a store that is not in the chain is an error, not a miss:
  /// `tryget` already means "this store may not have it", so it cannot
  /// also mean "this store may not exist" without hiding a typo.
  public func tryfrom(_ store: String, _ name: Name) throws -> String? {
    let matching = entries.filter { store == $0.store }

    if matching.isEmpty {
      throw SekretoError("sekreto: unknown store: \(store)")
    }

    return try resolve(store, name, matching)
  }

  private func resolve(_ store: String, _ name: Name, _ useentries: [Entry]) throws -> String? {
    // The name is validated first: before the cache, and before any
    // provider is asked.
    _ = try checkname(name)

    if docache {
      for hit in cache where store == hit.store && name == hit.name {
        return hit.value
      }
    }

    for entry in useentries {
      // A provider that throws is not caught: a store that could not
      // answer must not read as a store that does not hold the secret.
      if let found = try entry.provider.lookup(name) {
        if docache {
          cache.append(Cached(store: store, name: name, value: found))
        }
        seen.append(found)
        return found
      }
    }

    // A miss is never cached: the secret may arrive later.
    return nil
  }

  /// Does any provider have this secret?
  public func has(_ name: Name) throws -> Bool {
    return nil != (try tryget(name))
  }

  /// Does this named store have this secret?
  public func hasin(_ store: String, _ name: Name) throws -> Bool {
    return nil != (try tryfrom(store, name))
  }

  /// Every named secret at once. Missing ones are an error.
  public func all(_ names: [Name]) throws -> Ordered<String> {
    var out = Ordered<String>()

    for name in names {
      out[name] = try get(name)
    }

    return out
  }

  /// A description of each provider, in resolution order.
  public func sources() -> [String] {
    return entries.map { $0.provider.describe() }
  }

  /// The name of each store that can be named by `getfrom`, in resolution
  /// order and without repeats.
  public func stores() -> [String] {
    var out: [String] = []

    for entry in entries where !out.contains(entry.store) {
      out.append(entry.store)
    }

    return out
  }

  /// Replace every value this Sekreto has resolved with `[redacted]`.
  ///
  /// Works whether or not caching is enabled: the redaction list is kept
  /// independently of the read cache.
  public func redact(_ text: String) -> String {
    return sekretoredact(text, seen)
  }

  /// Drop cached values, so the next `get` asks the providers again.
  public func refresh() {
    cache.removeAll()
  }

  /// Tear the chain down: every plugin instance is deactivated and
  /// unloaded, in reverse, releasing whatever a provider acquired at
  /// activation.
  ///
  /// Afterwards there are no stores and nothing resolves - but redaction
  /// still knows every value ever resolved, so a log written after
  /// shutdown is no less safe than one written before.
  public func close() throws {
    try host.close()
    entries.removeAll()
    cache.removeAll()
  }

  /// Printed without its secrets.
  ///
  /// `cache` and `seen` are ordinary fields, so a derived description
  /// would put every resolved secret into whatever formatted it. Note the
  /// literal spacing: an empty chain prints `Sekreto { stores: [  ] }`.
  public var description: String {
    return "Sekreto { stores: [ " + stores().joined(separator: ", ") + " ] }"
  }

  /// The same, as data: the store names and nothing else.
  public func toJSON() -> Json {
    return Json.obj([("stores", .list(stores().map { Json.str($0) }))])
  }
}

/// The free `redact`, reachable from inside `Sekreto` where the member of
/// the same name would shadow it.
func sekretoredact(_ text: String, _ values: [String]) -> String {
  return redact(text as Any?, values.map { $0 as Any? })
}

/// Make a Sekreto from declarative provider specs - the same shape the
/// shared spec and an app's config file use.
///
/// `plugins` names the kinds beyond the four built-ins that `specs` may
/// use, as voxgig/plugin definitions. The calling project imports the
/// plugins it needs and passes them here; a kind it did not pass is
/// unknown to this Sekreto, and saying so is the point:
///
///     import SekretoPlugins
///     let secrets = try makesekreto(chain, plugins: [hashicorp])
///
/// `SekretoPlugins.allplugins` is the whole set, for a caller that wants
/// every kind - the CLI, the conformance suite, an app whose chain is
/// decided at run time.
public func makesekreto(
  _ specs: [ProviderSpec],
  plugins: [Definition] = [],
  cache: Bool = true
) throws -> Sekreto {
  return try Sekreto(specs: specs, plugins: plugins, cache: cache)
}
