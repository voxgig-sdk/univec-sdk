// The corpus test runner: vendored @voxgig/omni driven through its NATIVE
// API (`Omni.makeRunner(specref, provider)` / `RunPack.runsetflagsargs`),
// presented to the corpus suites in the struct-runner shape they already
// use (`run.spec`, `run.runset`, `run.runsetflags`, `run.client`). No
// compat shim is vendored: the adapter below IS the whole bridge, per
// language, per the vendor-tag rollout (docs/design/vendor-tag-rollout.md,
// Decision 4). It is the Swift peer of tm/csharp/test/OmniResolver.cs and
// tm/java/test/OmniResolver.java.
//
// Swift-specific decisions, each load-bearing:
//
// 1. THE VENDORED PORT IS ITS OWN MODULE. `Omni` is a SwiftPM target over
//    Tests/vendor/omni, not files folded into the test target: the port
//    calls `Omni.errify` by module name, and its top-level `clone`,
//    `getpath`, `walk`, `stringify` and `pathify` collide head-on with the
//    struct utility's functions of the same names. A .testTarget (not a
//    .target) keeps the engine out of `swift build`, so a consumer's
//    library build never compiles the test runner. Nothing outside this
//    file imports Omni - the corpus suites see `OmniSpec` and
//    `OmniResolver.Subject`, both spelled in the SDK's own Value model -
//    so the collisions stay contained to the one file that can qualify
//    them.
//
// 2. CONTEXTS STAY MAPS ACROSS THE RUNNER. omni sets `entry.ctx` to the
//    contextified args[0] and `match: {ctx: ...}` reads THROUGH it with
//    omni's own getpath, which walks JSON maps only. A typed Context there
//    would make every ctx assertion read "absent". So subjects receive the
//    MAP (an SDK `VMap`), build the typed Context with
//    `OmniResolver.omniCtx(args[0], ...)` at the call site, run the
//    utility, and write the observable ctx state back into the same map
//    with `omniSyncCtx` - the maps-plus-sync idiom go, java and csharp use
//    for the same contract (omni#56).
//
// 3. `match: {ctx: ...}` IS RETARGETED ONTO `match: {args: {"0": ...}}`.
//    This is the one place the Swift port cannot follow canonical omni as
//    written, and it is a VALUE-SEMANTICS consequence, not a choice.
//    omni's `Json` is an enum: `resolveargs` hands `entry.ctx` and
//    `args[0]` two COPIES of the contextified map, so a subject's writes -
//    decision 2's sync - can never reach the copy `entry.ctx` holds, and
//    `checkresult` reads `entry.get("ctx")` for the ctx base. The port
//    provides the channel for exactly this case: `runsetflagsargs` lets a
//    subject RETURN its arguments, and `checkresult` builds the `args`
//    base from what came back. args[0] IS the ctx of a ctx entry (omni
//    itself sets `args = [entry.get("ctx")]`), so moving the assertion
//    from `ctx` to `args.0` reads the SAME map, post-call, and preserves
//    every leaf. `retargetctx` below does that rewrite on the spec handed
//    to the engine; nothing is dropped, weakened, or skipped. PHP faces
//    the same copy-on-write problem and answers it with reference slots
//    (tm/php/test/Omni.php decision 2), which Swift's enum has no
//    equivalent of. The upstream fix is for the Swift port's `drive` to
//    re-point `entry.ctx` at the returned `callargs[0]`, the way JS object
//    identity does it implicitly - filed as a follow-up, not worked around
//    by editing a vendored file.
//
// 4. NUMBERS. omni's Json carries one numeric case (Double); the SDK's
//    Value distinguishes `.int` from `.double`, and struct's own
//    `stringify`/`jsonify` print them differently. An integral Double
//    therefore becomes `.int`, which is exactly what struct's JSON parser
//    does with the same text - the shared corpus carries no integral float
//    literal, so the mapping is lossless over it.
//
// 5. ZERO-ARGUMENT ENTRIES. A corpus entry with no `in`/`args`/`ctx`
//    means "call the subject with NO value". The vendored Swift port
//    distinguishes that natively - such an entry arrives as one
//    `Json.absent` - so Swift needs neither go's novalargs spec rewrite
//    nor lua/php's compat shim. The ONE conversion is the sentinel swap at
//    the call boundary: `.absent` -> `Value.noval` on the way in,
//    `Value.noval` -> `.absent` on the way out, so `typify()` answers
//    T_noval where a JSON null answers T_null.
//
// 6. THE VENDORED SWIFT PORT AT THIS TAG carries the omni#54 runner fixes
//    that matter here: `matchcheck` reads its base directly (no clone) and
//    tests the sentinels BEFORE the identity check. `jsonstr` has no cycle
//    guard, which only bites on cyclic values - decision 2 keeps typed
//    state (a Context, the SDK client) out of the maps the runner walks,
//    and the live provider crosses as an opaque `.native` leaf, so every
//    value the runner stringifies is acyclic.

import Foundation
import XCTest
import Omni

@testable import UnivecSdk

/// An omni spec node, in the engine's own value model. Opaque on purpose:
/// the corpus suites pass these around without importing Omni, whose
/// top-level `clone`/`getpath`/`walk`/`stringify`/`pathify` would collide
/// with the struct utility's (decision 1).
struct OmniSpec {
  fileprivate let json: Omni.Json

  fileprivate init(_ json: Omni.Json) { self.json = json }

  /// A child node by key (absent when missing).
  func get(_ key: String) -> OmniSpec { OmniSpec(json.get(key)) }

  /// A child node by path.
  func get(_ keys: [String]) -> OmniSpec {
    var cur = json
    for k in keys { cur = cur.get(k) }
    return OmniSpec(cur)
  }

  var isMap: Bool { json.ismap }
  var isAbsent: Bool { json.isabsent }

  /// The number of entries in this node's `set` list; nil when there is no
  /// `set` at all. The corpus suites use it to refuse a section that would
  /// run ZERO cases.
  var setCount: Int? { json.get("set").aslist?.count }

  /// This node in the SDK's own Value model (for DEF/setup reads).
  var value: Value { OmniResolver.tovalue(json) }
}

enum OmniResolver {

  // The sentinels, under the names the corpus suites already use.
  static let NULLMARK = Omni.NULLMARK
  static let UNDEFMARK = Omni.UNDEFMARK
  static let EXISTSMARK = Omni.EXISTSMARK

  /// The function under test, in omni's argument shape but the SDK's value
  /// model. Failure is reported by throwing.
  typealias Subject = ([Value]) throws -> Value

  /// A struct-corpus subject: one value in, one value out.
  typealias StructSubject = (Value) throws -> Value

  // ------------------------------------------------------------------
  // Errors
  // ------------------------------------------------------------------

  /// Did the engine itself fail an entry (as opposed to the subject
  /// throwing)? The smoke test asserts on this; the corpus suites turn it
  /// into an XCTFail carrying the entry.
  static func isOmniError(_ err: Error) -> Bool { err is Omni.OmniError }

  /// The message of any error, engine or subject.
  static func message(_ err: Error) -> String { Omni.errmessage(err) }

  /// A subject-side failure carrying a plain message. Used where the SDK's
  /// own port collects diagnostics instead of raising (struct's validate).
  struct SubjectError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
  }

  // ------------------------------------------------------------------
  // Value model conversion (decisions 4 and 5)
  // ------------------------------------------------------------------

  /// omni's model -> the SDK's.
  static func tovalue(_ j: Omni.Json) -> Value {
    switch j {
    case .absent: return .noval
    case .null: return .null
    case .bool(let b): return .bool(b)
    case .num(let d):
      if d == d.rounded(.towardZero), abs(d) < 9_007_199_254_740_992.0 {
        return .int(Int64(d))
      }
      return .double(d)
    case .str(let s): return .string(s)
    case .list(let items): return .list(VList(items.map { tovalue($0) }))
    case .map(let entries):
      let m = VMap()
      for (k, v) in entries { m.entries[k] = tovalue(v) }
      return .map(m)
    // The live provider omni attaches to a ctx map crosses as an opaque
    // leaf, keeping object identity so omniCtx can resolve it back.
    case .provider(let p): return .nat(p)
    }
  }

  /// The SDK's model -> omni's.
  static func tojson(_ v: Value) -> Omni.Json {
    switch v {
    case .noval: return .absent
    case .null: return .null
    case .bool(let b): return .bool(b)
    case .int(let n): return .num(Double(n))
    case .double(let d): return .num(d)
    case .string(let s): return .str(s)
    case .list(let l): return .list(l.items.map { tojson($0) })
    case .map(let m):
      var out: [(String, Omni.Json)] = []
      for (k, e) in m.entries { out.append((k, tojson(e))) }
      return .map(out)
    case .native(let ref):
      if let p = ref.value as? Omni.Provider { return .provider(p) }
      return .str("[native]")
    case .function: return .str("[function]")
    case .sentinel(let s): return .str(s.marker)
    }
  }

  // ------------------------------------------------------------------
  // Decision 3: retarget `match: {ctx: ...}` onto `match: {args: {"0": ...}}`
  // ------------------------------------------------------------------

  /// Rewrite every entry of a group so a ctx assertion reads the map the
  /// subject actually wrote to. Only entries that HAVE a ctx (or args)
  /// argument source are touched, and only when `match.args` is not
  /// already spoken for - anything else is left exactly as authored, so an
  /// unexpected shape fails loudly rather than being quietly rewritten.
  fileprivate static func retargetctx(_ testspec: Omni.Json) -> Omni.Json {
    guard let set = testspec.get("set").aslist else { return testspec }

    var out: [Omni.Json] = []
    for rawentry in set {
      var entry = rawentry
      let check = entry.get("match")
      if entry.ismap, check.ismap, check.has("ctx"), !check.has("args"),
        entry.has("ctx") || entry.has("args")
      {
        var newcheck = check
        newcheck.set("args", Omni.Json.mapOf([("0", check.get("ctx"))]))
        // Drop the original leaf: it would read the stale pre-call copy.
        if case .map(let fields) = newcheck {
          newcheck = .map(fields.filter { $0.0 != "ctx" })
        }
        entry.set("match", newcheck)
      }
      out.append(entry)
    }

    var spec = testspec
    spec.set("set", .list(out))
    return spec
  }

  // ------------------------------------------------------------------
  // Provider
  // ------------------------------------------------------------------

  // The live client behind each provider. A DEF.client entry builds a new
  // SDK instance, and omniCtx resolves it back off the ctx map's `client`
  // slot; only DEF-BUILT providers may override a call site's explicit
  // client, because the base provider rides on every ctx entry.
  private final class ProviderBox {
    var clients: [ObjectIdentifier: UnivecSDK] = [:]
    var defbuilt: Set<ObjectIdentifier> = []
    let lock = NSLock()
  }

  private static let providers = ProviderBox()

  private static func register(_ provider: Omni.Provider, _ client: UnivecSDK,
    _ isdef: Bool)
  {
    providers.lock.lock()
    defer { providers.lock.unlock() }
    providers.clients[ObjectIdentifier(provider)] = client
    if isdef { providers.defbuilt.insert(ObjectIdentifier(provider)) }
  }

  private static func defclient(_ provider: Omni.Provider) -> UnivecSDK? {
    providers.lock.lock()
    defer { providers.lock.unlock() }
    let id = ObjectIdentifier(provider)
    return providers.defbuilt.contains(id) ? providers.clients[id] : nil
  }

  /// Wrap a live client as an omni provider (decisions 2 and 3).
  private static func sdkProvider(_ client: UnivecSDK, _ isdef: Bool = false)
    -> Omni.Provider
  {
    let provider = Omni.Provider()

    // A DEF.client entry becomes another live test SDK, wrapped the same
    // way and marked DEF-built so omniCtx resolves it back.
    provider.client = { options in
      let opts = tovalue(options).asMap ?? VMap()
      return sdkProvider(UnivecSDK.testSDK(nil, opts), true)
    }

    // Client options may reference the runner store.
    provider.inject = { options, store in
      let o = tovalue(options)
      _ = UnivecSdk.inject(o, tovalue(store))
      return tojson(o)
    }

    // Keep the SDK error's code beside its message, so a corpus
    // `match: {err: {code: ...}}` can assert on it.
    provider.errify = { err in
      if let sdkerr = err as? UnivecError {
        var entries: [(String, Omni.Json)] = [
          ("name", .str("UnivecError")),
          ("message", .str(sdkerr.message)),
        ]
        if !sdkerr.code.isEmpty { entries.append(("code", .str(sdkerr.code))) }
        return .map(entries)
      }
      return Omni.errify(err)
    }

    register(provider, client, isdef)

    return provider
  }

  // ------------------------------------------------------------------
  // Run
  // ------------------------------------------------------------------

  /// What the runner returns for one named spec section - the struct-runner
  /// shape the corpus call sites consume.
  final class Run {
    /// The resolved section, in omni's model.
    let spec: OmniSpec
    /// The live SDK the provider wraps.
    let client: UnivecSDK

    private let pack: Omni.RunPack

    fileprivate init(_ pack: Omni.RunPack, _ client: UnivecSDK) {
      self.pack = pack
      self.spec = OmniSpec(pack.spec)
      self.client = client
    }

    /// A named group of the resolved spec.
    func set(_ name: String) -> OmniSpec { OmniSpec(pack.set(name)) }

    /// Run one group with omni's default flags.
    func runset(_ testspec: OmniSpec, _ subject: @escaping Subject) throws {
      try runsetflags(testspec, true, subject)
    }

    /// Run one group with an explicit `null` flag.
    func runsetflags(_ testspec: OmniSpec, _ nullFlag: Bool,
      _ subject: @escaping Subject) throws
    {
      try pack.runsetflagsargs(
        retargetctx(testspec.json), Omni.Flags(null: nullFlag),
        { jargs in
          // Maps and lists become VMap/VList - reference types - so a
          // subject's in-place writes (decision 2's omniSyncCtx, struct's
          // setpath) are visible in what we hand back as `callargs`, which
          // is where `match.args` reads (decision 3).
          let vargs = jargs.map { tovalue($0) }
          let res = try subject(vargs)
          return (vargs.map { tojson($0) }, tojson(res))
        })
    }
  }

  /// Resolves one named section of a loaded spec.
  typealias NamedRunner = (String) -> Run

  /// The struct runner's makeRunner(testfile, client) signature, backed by
  /// vendored omni. `testfile` is a spec path (absolutized against the
  /// working directory - omni's docs say a port must resolve the path
  /// itself).
  static func makeRunner(_ testfile: String, _ client: UnivecSDK) throws
    -> NamedRunner
  {
    let path = testfile.hasPrefix("/")
      ? testfile
      : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(testfile).path
    return try namedRunner(try Omni.makeRunner(path, sdkProvider(client)), client)
  }

  /// The same, for an already-parsed spec (omni's own capability), which
  /// keeps the smoke test free of fixture files.
  static func makeRunner(_ spec: Value, _ client: UnivecSDK) throws
    -> NamedRunner
  {
    return try namedRunner(try Omni.makeRunner(tojson(spec), sdkProvider(client)), client)
  }

  private static func namedRunner(_ runner: Omni.Runner, _ client: UnivecSDK)
    -> NamedRunner
  {
    return { name in Run(runner.runner(name), client) }
  }

  // ------------------------------------------------------------------
  // Contexts (decision 2)
  // ------------------------------------------------------------------

  /// Build the typed Context a generated utility takes from the ctx MAP
  /// omni handed the subject (args[0]). The map's `client` entry - an omni
  /// provider when a DEF entry selected one - resolves back to the live SDK
  /// it wraps; otherwise the given client is used.
  static func omniCtx(_ arg: Value, _ client: UnivecSDK, _ utility: Utility)
    -> Context
  {
    let ctxmap = arg.asMap ?? VMap()

    var usec = client
    var useu = utility
    if let ref = ctxmap.entries["client"]?.asNative as? Omni.Provider,
      let live = defclient(ref)
    {
      usec = live
      useu = live.getUtility()
    }

    let ctx = SdkRunner.makeCtxFromMap(ctxmap, usec, useu)
    SdkRunner.fixCtx(ctx, usec)
    return ctx
  }

  /// Write the OBSERVABLE state of a typed context back into the ctx map
  /// the entry holds, which is where a `match: {ctx: ...}` assertion reads
  /// (retargeted onto `match.args.0` - decision 3). The subject mutated the
  /// typed context; the map is what the runner can walk.
  static func omniSyncCtx(_ arg: Value, _ ctx: Context) {
    guard let ctxmap = arg.asMap else { return }

    if let spec = ctx.spec {
      let m = VMap()
      m.entries["base"] = .string(spec.base)
      m.entries["prefix"] = .string(spec.prefix)
      m.entries["suffix"] = .string(spec.suffix)
      m.entries["path"] = .string(spec.path)
      m.entries["method"] = .string(spec.method)
      m.entries["params"] = .map(spec.params)
      m.entries["query"] = .map(spec.query)
      m.entries["headers"] = .map(spec.headers)
      m.entries["step"] = .string(spec.step)
      m.entries["alias"] = .map(spec.alias)
      if !spec.body.isNoval { m.entries["body"] = spec.body }
      if !spec.url.isEmpty { m.entries["url"] = .string(spec.url) }
      ctxmap.entries["spec"] = .map(m)
    }

    if let result = ctx.result {
      let m = VMap()
      m.entries["ok"] = .bool(result.ok)
      m.entries["status"] = .int(Int64(result.status))
      m.entries["statusText"] = .string(result.statusText)
      m.entries["headers"] = .map(result.headers)
      if !result.body.isNoval { m.entries["body"] = result.body }
      if let err = result.err {
        let em = VMap()
        em.entries["message"] = .string(errMessage(err))
        m.entries["err"] = .map(em)
      }
      if !result.resdata.isNoval { m.entries["resdata"] = result.resdata }
      if let rm = result.resmatch { m.entries["resmatch"] = .map(rm) }
      ctxmap.entries["result"] = .map(m)
    }

    // Presence, not content: the corpus asserts `response: "__EXISTS__"`.
    // Written only when the subject really produced one, so the assertion
    // still fails when it did not.
    if ctx.response != nil {
      ctxmap.entries["response"] = .string("exists")
    }
  }

  // ------------------------------------------------------------------
  // The struct corpus's nullModifier
  // ------------------------------------------------------------------

  /// A bare "__NULL__" becomes a real null; an embedded one inside a larger
  /// string becomes the literal text "null". omni's own `nullmodifier`
  /// RETURNS the replacement, while struct's `inject` passes this as its
  /// `modify` hook and expects it to write `parent[key]` in place.
  static let nullModifier: Modify = { val, key, parent, _, _ in
    guard case .string(let text) = val else { return }
    if NULLMARK == text {
      setprop(parent, key, .null)
    } else if text.contains(NULLMARK) {
      setprop(parent, key, .string(text.replacingOccurrences(of: NULLMARK, with: "null")))
    }
  }
}
