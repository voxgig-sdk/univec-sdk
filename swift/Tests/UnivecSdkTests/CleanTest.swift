// The canary sweep: every credential slot holds a distinctive value, every
// diagnostic feature this SDK ships is switched on with a capturing sink, a
// real operation runs through every outcome, and every string that leaves
// the SDK is searched for the canaries and their encoded forms. It also
// proves its own sensitivity: with clean switched off the canary MUST show.

import Foundation
import XCTest

@testable import UnivecSdk

// Generated: the credential's wire placement is fixed when the SDK is built.
private let authSuppressed = false
private let authWhere = "header"
private let authName = "authorization"

private let canaryApikey = "CANARY-APIKEY-k9x2m7q4p1"
private let canarySecret = "CANARY-SECRET-w3e8r5t2y6"
private let canaryHeader = "CANARY-HEADER-z1x4c7v0b3"
private let canaryValue = "CANARY-VALUE-n5m8b2v9c4"
private let canaryConfig = "CANARY-CONFIG-h6j3k8l2m5"

private let mask = "[redacted]"

// encodeURIComponent's unreserved set.
private let unreserved = CharacterSet(
  charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

private func base64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

private func percent(_ s: String) -> String {
  s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
}

// Every form a canary can travel in.
private let forms: [String] = {
  var out: [String] = []
  for v in [canaryApikey, canarySecret, canaryHeader, canaryValue, canaryConfig] {
    out.append(v)
    out.append(base64(v))
    out.append(percent(v))
  }
  out.append(base64(canaryApikey + ":" + canarySecret))
  return out
}()

private func leaks(_ text: String) -> [String] {
  forms.filter { text.contains($0) }
}

// Header maps keep the caller's spelling; the assertion should not care.
private func header(_ map: Value, _ name: String) -> Value {
  guard let m = map.asMap else { return .noval }
  for (k, v) in m.entries where k.caseInsensitiveCompare(name) == .orderedSame {
    return v
  }
  return .noval
}

private func response(_ status: Int, _ data: Value, _ headers: [(String, String)] = []) -> Value {
  let h = VMap()
  h.entries["content-type"] = .string("application/json")
  for (k, v) in headers { h.entries[k.lowercased()] = .string(v) }
  let m = VMap()
  m.entries["status"] = .int(Int64(status))
  m.entries["statusText"] = .string(status < 400 ? "OK" : "ERR")
  m.entries["json"] = .nat({ () -> Value in data } as NativeCall0)
  m.entries["body"] = .string(jsonify(data, indent: 0))
  m.entries["headers"] = .map(h)
  return .map(m)
}

// The typed pipeline products read through their stored properties, so the
// raw spec is visible when clean is off - the sensitivity check depends on it.
private func render(_ any: Any?, _ depth: Int = 0) -> String {
  guard let any = any, depth < 8 else { return "null" }
  if let v = any as? Value {
    if let n = v.asNative { return render(n, depth + 1) }
    return jsonify(v, indent: 0)
  }
  if let m = any as? VMap { return jsonify(.map(m), indent: 0) }
  if let s = any as? String { return s }
  if let sp = any as? Spec {
    let m = VMap()
    m.entries["method"] = .string(sp.method)
    m.entries["url"] = .string(sp.url)
    m.entries["path"] = .string(sp.path)
    m.entries["headers"] = .map(sp.headers)
    m.entries["query"] = .map(sp.query)
    m.entries["params"] = .map(sp.params)
    m.entries["body"] = sp.body
    return jsonify(.map(m), indent: 0)
  }
  if let ent = any as? Entity { return jsonify(ent.data(), indent: 0) }
  if let ctx = any as? Context { return jsonify(.map(ctx.record()), indent: 0) }
  if let e = any as? UnivecError { return jsonify(.map(e.record()), indent: 0) }
  var out = ""
  dump(any, to: &out, maxDepth: 8)
  return out
}

final class UnivecCleanTest: XCTestCase {

  struct Sink {
    let name: String
    let text: String
  }

  // A reference the capturing closures share.
  final class SinkBox {
    var sinks: [Sink] = []
  }

  struct Candidate {
    let name: String
    let accessor: (UnivecSDK) -> UnivecEntityBase
    let ops: [String]
    let params: [String: [String]]
  }

  struct Target {
    let candidate: Candidate
    let op: String
    let params: [String]
  }

  struct TransportError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
  }

  struct Scenario {
    let name: String
    let respond: (String, VMap) throws -> Value
  }

  // Every default print a value has, plus the SDK's own record of it.
  static func formsOf(_ name: String, _ val: Any?) -> [Sink] {
    var out: [Sink] = []
    func push(_ kind: String, _ fn: () -> String) {
      out.append(Sink(name: name + ":" + kind, text: fn()))
    }
    guard let val = val else { return out }
    push("describing") { String(describing: val) }
    push("reflecting") { String(reflecting: val) }
    push("dump") {
      var s = ""
      dump(val, to: &s, maxDepth: 8)
      return s
    }
    push("render") { render(val) }
    if let v = val as? Value { push("json") { jsonify(v, indent: 0) } }
    if let m = val as? VMap { push("json") { jsonify(.map(m), indent: 0) } }
    if let e = val as? UnivecError {
      push("message") { e.message }
      push("record") { jsonify(.map(e.record()), indent: 0) }
    }
    if let e = val as? Error { push("message") { errMessage(e) } }
    if let c = val as? Context { push("record") { jsonify(.map(c.record()), indent: 0) } }
    return out
  }

  // Captures the serialised context from inside the pipeline: what a hook
  // author would hand to a logger.
  final class CaptureFeature: BaseFeature {
    let box: SinkBox
    init(_ box: SinkBox) {
      self.box = box
      super.init()
      name = "capture"
      version = "0.0.1"
      active = true
    }
    override func preRequest(_ ctx: Context) { box.sinks += UnivecCleanTest.formsOf("ctx@PreRequest", ctx) }
    override func preResponse(_ ctx: Context) { box.sinks += UnivecCleanTest.formsOf("ctx@PreResponse", ctx) }

    // The SDK's own error as a hook reads it, which an observability feature
    // logs.
    override func preUnexpected(_ ctx: Context) {
      box.sinks += UnivecCleanTest.formsOf("ctx@PreUnexpected", ctx)
      if let err = ctx.ctrl.err as? UnivecError {
        box.sinks += UnivecCleanTest.formsOf("ctrl.err@PreUnexpected", err)
      }
    }
  }

  // A feature that fails the operation from inside the pipeline, quoting the
  // request it saw. A swift hook cannot throw, so it fails the response the
  // way a hook can, and the error never came from makeError.
  final class FailFeature: BaseFeature {
    override init() {
      super.init()
      name = "throwhook"
      version = "0.0.1"
      active = true
    }
    override func preResponse(_ ctx: Context) {
      ctx.response?.err = TransportError(message: "hook saw " + render(ctx.spec))
    }
  }

  // A stream that succeeds, yielding the result's items.
  final class StreamOkFeature: BaseFeature {
    override init() {
      super.init()
      name = "streamok"
      version = "0.0.1"
      active = true
    }
    override func preDone(_ ctx: Context) {
      guard let result = ctx.result else { return }
      let items: [Value] = result.resdata.asList?.items ?? (isNil(result.resdata) ? [] : [result.resdata])
      result.stream = { items }
    }
  }

  static let scenarios: [Scenario] = [
    Scenario(name: "ok", respond: { _, _ in
      response(200, .map(vm(("id", .string("i1")), ("name", .string("n1")))),
        [("x-session-token", "RESP-TOKEN-a1b2c3d4e5")])
    }),
    Scenario(name: "notfound", respond: { _, _ in
      response(404, .map(vm(("error", .string("no such record")))))
    }),
    Scenario(name: "server", respond: { _, _ in
      response(500, .map(vm(("error", .string("boom")))))
    }),
    Scenario(name: "transport", respond: { url, _ in
      throw TransportError(message: "socket hang up (URL was: \"" + url + "\")")
    }),
    // The SDK's own error, its code quoting a registered value.
    Scenario(name: "coded", respond: { _, _ in
      throw UnivecError("denied_" + canaryApikey, "coded failure", nil)
    }),
    Scenario(name: "notjson", respond: { _, _ in
      let m = VMap()
      m.entries["status"] = .int(200)
      m.entries["statusText"] = .string("OK")
      m.entries["json"] = .nat({ () -> Value in .noval } as NativeCall0)
      m.entries["body"] = .string("<html>")
      m.entries["headers"] = .map(VMap())
      return .map(m)
    }),
  ]

  // True when this SDK was generated with the named feature.
  static func hasFeature(_ name: String) -> Bool {
    gp(SdkConfig.makeConfig(), "feature").asMap?.entries[name] != nil
  }

  // Offline, as every generated suite is: the test OPTION resolves a required
  // server variable to test-<name>, and installs no transport. A construction
  // that fails traps, which no harness can catch, so the option is the guard.
  static func offline(_ opts: VMap) -> VMap {
    let out = VMap()
    for (k, v) in opts.entries { out.entries[k] = v }
    out.entries["test"] = .map(vm(("active", .bool(true))))
    return out
  }

  static func makeSdk(
    _ scenario: Scenario, _ box: SinkBox, _ cleanopts: VMap? = nil, _ extra: [BaseFeature] = [],
    auth: VMap? = nil
  ) -> UnivecSDK {
    func capture(_ name: String) -> (VMap) -> Void {
      return { rec in box.sinks += formsOf(name, rec) }
    }

    let feature = VMap()
    if hasFeature("log") {
      let logger: (String, String, VMap) -> Void = { level, _, attrs in
        box.sinks += formsOf("log." + level, attrs)
      }
      feature.entries["log"] = .map(vm(("active", .bool(true)), ("logger", .nat(logger))))
    }
    if hasFeature("debug") {
      feature.entries["debug"] = .map(vm(("active", .bool(true)), ("onEntry", .nat(capture("debug")))))
    }
    if hasFeature("audit") {
      feature.entries["audit"] = .map(vm(("active", .bool(true)), ("sink", .nat(capture("audit")))))
    }
    if hasFeature("telemetry") {
      feature.entries["telemetry"] = .map(vm(("active", .bool(true)), ("exporter", .nat(capture("telemetry")))))
    }
    if hasFeature("cost") {
      let sink: (CostRecord) -> Void = { rec in box.sinks += formsOf("cost", rec) }
      feature.entries["cost"] = .map(vm(("active", .bool(true)), ("sink", .nat(sink))))
    }
    if hasFeature("metrics") {
      feature.entries["metrics"] = .map(vm(("active", .bool(true))))
    }
    if hasFeature("clienttrack") {
      feature.entries["clienttrack"] = .map(vm(("active", .bool(true))))
    }

    let clean = VMap()
    clean.entries["values"] = .string(canaryValue)
    if let extra = cleanopts {
      for (k, v) in extra.entries { clean.entries[k] = v }
    }

    let fetch: FetcherFunc = { _, url, fetchdef in try scenario.respond(url, fetchdef) }

    let opts = VMap()
    opts.entries["apikey"] = .string(canaryApikey)
    opts.entries["secret"] = .string(canarySecret)
    opts.entries["headers"] = .map(vm(("X-Custom-Token", .string(canaryHeader))))
    opts.entries["clean"] = .map(clean)
    opts.entries["feature"] = .map(feature)
    var extend: [Value] = [.nat(CaptureFeature(box))]
    for f in extra { extend.append(.nat(f)) }
    opts.entries["extend"] = .list(VList(extend))
    opts.entries["utility"] = .map(vm(("fetcher", .nat(fetch))))
    if let a = auth { opts.entries["auth"] = .map(a) }
    return UnivecSDK(UnivecCleanTest.offline(opts))
  }

  // Emitted from the model: every active entity with the operations it
  // declares, list and load first.
  static let candidates: [Candidate] = [
    Candidate(name: "convert", accessor: { $0.Convert(nil) }, ops: ["create"], params: ["create": []]),
    Candidate(name: "embed", accessor: { $0.Embed(nil) }, ops: ["create"], params: ["create": []]),
    Candidate(name: "ephemeral_key", accessor: { $0.EphemeralKey(nil) }, ops: ["create"], params: ["create": []]),
    Candidate(name: "model", accessor: { $0.Model(nil) }, ops: ["list"], params: ["list": []]),
  ]

  static func invoke(
    _ ent: UnivecEntityBase, _ op: String, _ params: [String], _ ctrl: VMap?
  ) throws -> Value {
    let args = VMap()
    for p in params { args.entries[p] = .string("p1") }
    switch op {
    case "list": return try ent.list(args, ctrl)
    case "load": return try ent.load(args, ctrl)
    case "create": return try ent.create(args, ctrl)
    case "update": return try ent.update(args, ctrl)
    case "patch": return try ent.patch(args, ctrl)
    case "remove": return try ent.remove(args, ctrl)
    default: throw TransportError(message: "unknown operation: " + op)
    }
  }

  // The first operation that completes against a plain 200: with no
  // arguments, else with every path parameter its points declare filled in.
  static func usableOp() -> Target? {
    let fetch: FetcherFunc = { _, _, _ in response(200, .map(vm(("id", .string("i1"))))) }
    let opts = VMap()
    opts.entries["apikey"] = .string(canaryApikey)
    opts.entries["utility"] = .map(vm(("fetcher", .nat(fetch))))
    let plain = UnivecSDK(UnivecCleanTest.offline(opts))
    for candidate in candidates {
      for op in candidate.ops {
        let filled: [String] = candidate.params[op] ?? []
        for params in [[], filled] {
          if (try? invoke(candidate.accessor(plain), op, params, nil)) != nil {
            return Target(candidate: candidate, op: op, params: params)
          }
        }
      }
    }
    return nil
  }

  static func drive(_ sdk: UnivecSDK, _ target: Target, _ ctrl: VMap, _ box: SinkBox) -> Error? {
    // A caller may keep the record it passed rather than read ctrl["explain"].
    let held = ctrl.entries["explain"]?.asMap
    let entity = target.candidate.accessor(sdk)
    var out: Value = .noval
    var err: Error? = nil
    do {
      out = try invoke(entity, target.op, target.params, ctrl)
    } catch {
      err = error
    }
    if let e = err { box.sinks += formsOf("error", e) }
    if !isNil(out) { box.sinks += formsOf("result", out) }
    // Raw, as a caller copying the match into another query reads it.
    box.sinks += formsOf("match", entity.matchv(nil))
    if let explain = ctrl.entries["explain"]?.asMap { box.sinks += formsOf("explain", explain) }
    if let h = held, h !== ctrl.entries["explain"]?.asMap { box.sinks += formsOf("explain:held", h) }
    return err
  }

  func testNoCredentialLeavesTheSdkInAnyForm() throws {
    guard let target = UnivecCleanTest.usableOp() else {
      throw XCTSkip("no operation of this SDK completes against a plain 200; nothing to sweep")
    }

    let box = SinkBox()
    var errors: [String: Error] = [:]
    var explains: [String: VMap] = [:]

    let variants: [(String, () -> VMap)] = [
      ("throw", { VMap() }),
      ("explain", { vm(("explain", .map(VMap()))) }),
      ("nothrow", { vm(("throw", .bool(false)), ("explain", .map(VMap()))) }),
    ]

    for scenario in UnivecCleanTest.scenarios {
      for (vname, makeCtrl) in variants {
        let sdk = UnivecCleanTest.makeSdk(scenario, box)
        let ctrl = makeCtrl()
        let err = UnivecCleanTest.drive(sdk, target, ctrl, box)
        let key = scenario.name + "/" + vname
        if let e = err { errors[key] = e }
        if let ex = ctrl.entries["explain"]?.asMap { explains[key] = ex }
        box.sinks += UnivecCleanTest.formsOf("sdk", sdk)
      }
    }

    // A name given at run time replaces the declared one: the match leaves
    // out whichever name prepareAuth placed.
    _ = UnivecCleanTest.drive(
      UnivecCleanTest.makeSdk(UnivecCleanTest.scenarios[0], box, auth: vm(("name", .string("zzcred")))),
      target, VMap(), box)

    // A credential mistyped as a map. This struct port's validate collects
    // its errors instead of throwing, so nothing rejects it: the client it
    // produced is swept instead.
    let mistyped = VMap()
    mistyped.entries["apikey"] = .map(vm(("value", .string(canaryApikey))))
    mistyped.entries["clean"] = .map(vm(("values", .string(canaryValue))))
    box.sinks += UnivecCleanTest.formsOf("mistyped", UnivecSDK(UnivecCleanTest.offline(mistyped)))

    // An error a feature hook raises, quoting the request, skips makeError.
    // A swift hook cannot throw, so no variant fails from PreUnexpected.
    let hooked = UnivecCleanTest.makeSdk(UnivecCleanTest.scenarios[0], box, nil, [FailFeature()])
    let hookerr = UnivecCleanTest.drive(hooked, target, vm(("explain", .map(VMap()))), box)
    XCTAssertNotNil(hookerr, "the failing hook should fail the operation")

    // The explain record a stream call carries is cleaned however the stream
    // is fed. A swift stream cannot raise, so there is no failing variant,
    // and the record is complete once stream() returns.
    let streams: [(String, [BaseFeature])] = [("stream-ok", [StreamOkFeature()]), ("stream-plain", [])]
    for (label, extra) in streams {
      let explain = VMap()
      let streamed = UnivecCleanTest.makeSdk(UnivecCleanTest.scenarios[0], box, nil, extra)
      XCTAssertNoThrow(try target.candidate.accessor(streamed).stream(
        target.op, nil, vm(("ctrl", .map(vm(("explain", .map(explain))))))), label + ": the stream should not fail")
      XCTAssertFalse(explain.entries.isEmpty, label + ": the explain record was not filled")
      box.sinks += UnivecCleanTest.formsOf(label + ":explain", explain)
    }

    // The generated config's own clean block is read beside the caller's,
    // and is not changed by it.
    let config = vm(("options", .map(vm(("clean", .map(vm(
      ("keys", .string("zzsens")), ("values", .string(canaryConfig)))))))))
    let built = makeOptionsUtil(Context(
      ["config": config, "options": vm(("clean", .map(vm(("values", .string(canaryValue))))))], nil))
    let cfgctx = Context(["options": built], nil)
    let seeded = cleanUtil(cfgctx, .string("config " + canaryConfig + " caller " + canaryValue)).asString ?? ""
    box.sinks.append(Sink(name: "config-clean", text: seeded))
    XCTAssertEqual(seeded, "config " + mask + " caller " + mask)
    let bykey = cleanUtil(cfgctx, .map(vm(("my_zzsens", .string("x")), ("other", .string("y"))))).asMap
    XCTAssertEqual(bykey?.entries["my_zzsens"], Value.string(mask))
    XCTAssertEqual(bykey?.entries["other"], Value.string("y"))
    XCTAssertEqual(gpath(config, "options", "clean", "values"), .string(canaryConfig))
    XCTAssertEqual(gpath(config, "options", "clean", "keys"), .string("zzsens"))

    // A coded SDK error inside a structure is cleaned like any other field.
    let nested = cleanUtil(cfgctx, .map(vm(
      ("err", .nat(UnivecError("denied_" + canaryValue, "coded failure", nil))))))
    box.sinks += UnivecCleanTest.formsOf("coded-nested", nested)

    // With no clean option at all, or one that is not a map, the schema
    // defaults still apply.
    for clean in [Value.noval, Value.bool(true)] {
      let fetch404: FetcherFunc = { _, url, fetchdef in
        try UnivecCleanTest.scenarios[1].respond(url, fetchdef)
      }
      let bareopts = VMap()
      bareopts.entries["apikey"] = .string(canaryApikey)
      bareopts.entries["secret"] = .string(canarySecret)
      bareopts.entries["headers"] = .map(vm(("X-Custom-Token", .string(canaryHeader))))
      bareopts.entries["utility"] = .map(vm(("fetcher", .nat(fetch404))))
      if !isNil(clean) {
        bareopts.entries["clean"] = clean
      }
      let bareerr = UnivecCleanTest.drive(
        UnivecSDK(UnivecCleanTest.offline(bareopts)), target, vm(("explain", .map(VMap()))), box)
      XCTAssertNotNil(bareerr, "the 404 should fail with clean: " + stringify(clean))
    }

    // A feature's name is not a field name: only the sensitive names inside
    // its settings register. An entity block, of entity settings or seeded
    // records keyed by entity name and id, is not read at all, and nor are
    // rbac's rules, keyed by entity and operation names.
    let record = vm(("zztoken", .map(vm(("ZZTOKEN01", .map(vm(("note", .string("PLAINRECORD-t5r3e1w9")))))))))
    let alias = vm(("zztoken", .map(vm(("alias", .map(vm(("zzkey", .string("PLAINALIAS-m2n4b6v8")))))))))
    let featopts = VMap()
    featopts.entries["apikey"] = .string(canaryApikey)
    featopts.entries["feature"] = .map(vm(
      ("zzsecrets", .map(vm(("active", .bool(false)), ("kind", .string("PLAINSETTING-q8w2e4r6"))))),
      ("zzfeat", .map(vm(("active", .bool(false)), ("apitoken", .string("FEATTOKEN-z9y8x7w6"))))),
      ("rbac", .map(vm(("active", .bool(false)),
        ("rules", .map(vm(("zztoken.load", .string("PLAINRULE-k7j5h3g1")))))))),
      ("test", .map(vm(("active", .bool(false)), ("entity", .map(record)))))))
    featopts.entries["entity"] = .map(alias)
    let fctx = Context(["options": makeOptionsUtil(Context(["options": featopts], nil))], nil)
    let fplain = cleanUtil(fctx, .string("kind PLAINSETTING-q8w2e4r6")).asString
    let ftoken = cleanUtil(fctx, .string("token FEATTOKEN-z9y8x7w6")).asString
    let frecord = cleanUtil(fctx, .string("record PLAINRECORD-t5r3e1w9")).asString
    let falias = cleanUtil(fctx, .string("alias PLAINALIAS-m2n4b6v8")).asString
    let frule = cleanUtil(fctx, .string("rule PLAINRULE-k7j5h3g1")).asString

    // direct() returns its error rather than throwing it. Only the SDK's own
    // error can be cleaned in place, so the coded transport is the one used.
    let raw = UnivecCleanTest.makeSdk(UnivecCleanTest.scenarios[4], box).direct(vm(("path", .string("raw"))))
    XCTAssertEqual(gp(raw, "ok"), .bool(false))
    let rawerr = gp(raw, "err").asNative as? UnivecError
    box.sinks += UnivecCleanTest.formsOf("direct", rawerr)

    let leaked = box.sinks
      .map { (name: $0.name, found: leaks($0.text)) }
      .filter { !$0.found.isEmpty }

    print("clean: swept \(box.sinks.count) surface(s), \(leaked.count) leak(s)")

    XCTAssertEqual(leaked.count, 0, "credential leaked through: " +
      leaked.map { $0.name + " [" + $0.found.joined(separator: ", ") + "]" }.joined(separator: "; "))

    // The positive half: the slot the credential travelled in is masked,
    // and an unregistered token in a response header is masked by name.
    guard let notfound = errors["notfound/throw"] as? UnivecError else {
      XCTFail("the 404 scenario must throw")
      return
    }
    XCTAssertEqual(notfound.status, 404)
    let spec = notfound.specVal
    if !authSuppressed {
      if "query" == authWhere {
        XCTAssertEqual(header(gp(spec, "query"), authName), .string(mask))
      } else if "cookie" == authWhere {
        let cookie = header(gp(spec, "headers"), "cookie").asString ?? ""
        XCTAssertTrue(cookie.contains(mask), "cookie: " + cookie)
      } else {
        let cred = header(gp(spec, "headers"), authName).asString ?? ""
        XCTAssertTrue(cred.hasSuffix(mask), authName + ": " + cred)
      }
    }
    XCTAssertEqual(header(gp(spec, "headers"), "x-custom-token"), .string(mask))

    XCTAssertEqual((errors["coded/throw"] as? UnivecError)?.code, "denied_" + mask)

    XCTAssertEqual(fplain, "kind PLAINSETTING-q8w2e4r6")
    XCTAssertEqual(ftoken, "token " + mask)
    XCTAssertEqual(frecord, "record PLAINRECORD-t5r3e1w9")
    XCTAssertEqual(falias, "alias PLAINALIAS-m2n4b6v8")
    XCTAssertEqual(frule, "rule PLAINRULE-k7j5h3g1")
    XCTAssertEqual(rawerr?.code, "denied_" + mask)

    let explained = explains["ok/explain"] ?? VMap()
    let result = gp(explained, "result")
    XCTAssertFalse(isNil(result), "the explain record should carry the result")
    XCTAssertEqual(header(gp(result, "headers"), "x-session-token"), .string(mask))
  }

  func testTheSweepCanSeeALeakCleanSwitchedOffShowsTheCredential() throws {
    guard let target = UnivecCleanTest.usableOp() else {
      throw XCTSkip("no operation of this SDK completes against a plain 200; nothing to sweep")
    }

    let box = SinkBox()
    let sdk = UnivecCleanTest.makeSdk(UnivecCleanTest.scenarios[1], box, vm(("active", .bool(false))))
    let err = UnivecCleanTest.drive(sdk, target, VMap(), box)
    XCTAssertNotNil(err, "the 404 scenario must throw")

    // Explaining a failure must not cost it its error.
    let explained = UnivecCleanTest.drive(
      UnivecCleanTest.makeSdk(UnivecCleanTest.scenarios[1], SinkBox(), vm(("active", .bool(false)))),
      target, vm(("explain", .map(VMap()))), SinkBox())
    XCTAssertEqual(explained.map { errMessage($0) }, err.map { errMessage($0) },
      "with clean off, explain lost the error")

    let leaked = box.sinks.filter { !leaks($0.text).isEmpty }
    XCTAssertTrue(!leaked.isEmpty, "with clean off, nothing showed the canary: the sweep is blind")

    if !authSuppressed, let e = err as? UnivecError {
      let text = render(e.specVal)
      XCTAssertTrue(text.contains(canaryApikey) || text.contains(base64(canaryApikey + ":" + canarySecret)),
        "the raw spec should carry the credential when clean is off")
    }
  }

  func testARegisteredValueUsedAsAPropertyNameIsMaskedCollisionsKept() {
    let cfg = makeCleanConfig(gp(SdkSchema.optspec, "clean"))
    let ctx = Context(["options": vm(("__derived__", .map(vm(("clean", .nat(cfg))))))], nil)
    cleanAddUtil(ctx, .string("ZZVAL-abc123"))
    cleanAddUtil(ctx, .string("ZZVAL-xyz789"))
    let src = vm(("ZZVAL-abc123", .int(1)), ("ZZVAL-xyz789", .int(2)), ("plain", .int(3)))
    guard let out = cleanUtil(ctx, .map(src)).asMap else {
      XCTFail("clean of a map should be a map")
      return
    }
    XCTAssertEqual(out.entries[mask], Value.int(1))
    XCTAssertEqual(out.entries[mask + "#1"], Value.int(2))
    XCTAssertEqual(out.entries["plain"], Value.int(3))
    XCTAssertNil(out.entries["ZZVAL-abc123"])
  }

  func testCleanAddSensitiveRegistersEveryScalarUnderASensitiveName() {
    let cfg = makeCleanConfig(gp(SdkSchema.optspec, "clean"))
    let ctx = Context(["options": vm(("__derived__", .map(vm(("clean", .nat(cfg))))))], nil)
    cleanAddSensitiveUtil(ctx, .map(vm(
      ("apikey", .map(vm(("value", .string("NESTED-SECRET-1"))))),
      ("headers", .map(vm(("X-Api-Token", .list(VList([.string("LISTED-SECRET-2")])))))),
      ("secret", .int(123456789)),
      ("name", .string("not-a-secret")))))
    XCTAssertTrue(cfg.values.contains("NESTED-SECRET-1"))
    XCTAssertTrue(cfg.values.contains("LISTED-SECRET-2"))
    XCTAssertTrue(cfg.values.contains("123456789"))
    XCTAssertFalse(cfg.values.contains("not-a-secret"))
  }
}
