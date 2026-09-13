// Primary utility test suite - drives every utility on the client utility
// object against the shared corpus in ../../../.sdk/test/test.json
// ("primary" section) through the VENDORED omni runner (OmniResolver over
// Tests/vendor/omni), plus direct checks. Swift twin of
// tm/csharp/test/PrimaryUtilityTest.cs and tm/go/test/primary_utility_test.go.
//
// Subjects receive omni's native argument list in the SDK's value model: a
// ctx entry arrives as args[0], a MAP - OmniResolver.omniCtx builds the
// typed Context a generated utility takes, and OmniResolver.omniSyncCtx
// writes the observable ctx state back for `match: {ctx: ...}` assertions
// (which the resolver retargets onto `match.args.0`, its decision 3).

import XCTest

@testable import UnivecSdk

// Helper: test hook feature for the featureHook test. featureHook dispatches an
// unknown hook name to customHook, so "TestHook" routes here.
final class TestHookFeature: BaseFeature {
  var hookFn: (() -> Void)?

  override func customHook(_ name: String, _ ctx: Context) {
    if name == "TestHook" { hookFn?() }
  }
}

// Helper: test init feature for the featureInit test. featureInit only fires
// when options.feature.<name>.active is true.
final class TestInitFeature: BaseFeature {
  var initFn: (() -> Void)?

  override func initFeature(_ ctx: Context, _ options: VMap) {
    initFn?()
  }
}

final class PrimaryUtilityTest: XCTestCase {
  // PENDING sections are the ones deliberately left EMPTY in the shared
  // corpus (.sdk/test/primary/<name>.aon). Everything else MUST contribute
  // cases: a renamed section or a fixture that failed to compile used to
  // report PASS while running zero assertions.
  private static let PENDING: Set<String> = [
    "fetcher", "makeFetchDef", "makeResult",
    "featureAdd", "featureHook", "featureInit",
  ]

  // One corpus runner for the whole suite (XCTest builds a fresh instance
  // per test method, so the runner is static).
  private static var RUN: OmniResolver.Run?
  private static let runLock = NSLock()

  private static func primaryRun() throws -> OmniResolver.Run {
    runLock.lock()
    defer { runLock.unlock() }
    if let run = RUN { return run }
    let run = try OmniResolver.makeRunner(
      SdkRunner.testJsonPath(), UnivecSDK.testSDK(nil, nil))("primary")
    RUN = run
    return run
  }

  // XCTestCase has no custom init; set these up per test.
  private var client: UnivecSDK!
  private var utility: Utility!

  override func setUp() {
    super.setUp()
    client = UnivecSDK.testSDK(nil, nil)
    utility = client.getUtility()
  }

  // Run one corpus section through the vendored engine, failing loudly when
  // it would run ZERO cases.
  private func runsection(
    _ name: String, _ subject: @escaping OmniResolver.Subject,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    do {
      let run = try PrimaryUtilityTest.primaryRun()

      let section = run.spec.get(name)
      guard section.isMap else {
        return XCTFail("test corpus section \"\(name)\" missing - check the " +
          "name against .sdk/test/primary/", file: file, line: line)
      }
      let basic = section.get("basic")
      guard let count = basic.setCount else {
        return XCTFail("test corpus section \"\(name)\" has no basic.set list " +
          "- zero cases would run", file: file, line: line)
      }
      if 0 == count && !PrimaryUtilityTest.PENDING.contains(name) {
        return XCTFail("test corpus section \"\(name)\" is EMPTY - zero cases " +
          "would run; add cases, or mark the fixture PENDING in " +
          ".sdk/test/primary/", file: file, line: line)
      }
      if 0 == count { return }

      try run.runset(basic, subject)
      print("ok primary.\(name): \(count)/\(count)")
    } catch {
      XCTFail("primary.\(name): \(OmniResolver.message(error))",
        file: file, line: line)
    }
  }

  // The DEF.setup options a section names, as SDK options.
  private func setupOptions(_ name: String, _ key: String) throws -> VMap? {
    try PrimaryUtilityTest.primaryRun().spec
      .get([name, "DEF", "setup", key]).value.asMap
  }

  // MARK: - Local helpers

  // Unwrap a loose Value scalar/node to the native Swift form Context expects
  // (opname must be a String, config/options must be a VMap, etc.). This is the
  // Swift twin of the C# donor passing a native Dictionary to MakeContext.
  private func nativeValue(_ v: Value) -> Any? {
    switch v {
    case .string(let s): return s
    case .int(let n): return n
    case .double(let d): return d
    case .bool(let b): return b
    case .noval, .null: return nil
    case .map(let m): return m
    case .list(let l): return l
    default: return v
    }
  }

  private func nativeCtxMap(_ m: VMap) -> [String: Any?] {
    var out: [String: Any?] = [:]
    for (k, v) in m.entries { out[k] = nativeValue(v) }
    return out
  }

  // Helper: create basic test context.
  private func makeTestCtx(_ client: UnivecSDK, _ utility: Utility,
    _ overrides: [String: Any?]?) -> Context
  {
    var ctxmap: [String: Any?] = [
      "opname": "load",
      "client": client,
      "utility": utility,
    ]
    if let overrides = overrides {
      for (k, v) in overrides { ctxmap[k] = v }
    }
    return utility.makeContext(ctxmap, client.getRootCtx())
  }

  // Helper: create full test context with point and match.
  private func makeTestFullCtx(_ client: UnivecSDK, _ utility: Utility) -> Context {
    let ctx = makeTestCtx(client, utility, nil)

    let paramDef = vm(("name", .string("id")), ("reqd", .bool(true)))
    let point = vm(
      ("parts", .list([.string("items"), .string("{id}")])),
      ("args", .map(vm(("params", .list([.map(paramDef)]))))),
      ("params", .list([.string("id")])),
      ("alias", .map(VMap())),
      ("select", .map(VMap())),
      ("active", .bool(true)),
      ("transform", .map(VMap()))
    )
    ctx.point = point
    ctx.match = vm(("id", .string("item01")))
    ctx.reqmatch = vm(("id", .string("item01")))
    return ctx
  }

  // MARK: - Direct checks

  func testExists() {
    XCTAssertNotNil(utility.clean)
    XCTAssertNotNil(utility.done)
    XCTAssertNotNil(utility.makeError)
    XCTAssertNotNil(utility.featureAdd)
    XCTAssertNotNil(utility.featureHook)
    XCTAssertNotNil(utility.featureInit)
    XCTAssertNotNil(utility.fetcher)
    XCTAssertNotNil(utility.makeFetchDef)
    XCTAssertNotNil(utility.makeContext)
    XCTAssertNotNil(utility.makeOptions)
    XCTAssertNotNil(utility.makeRequest)
    XCTAssertNotNil(utility.makeResponse)
    XCTAssertNotNil(utility.makeResult)
    XCTAssertNotNil(utility.makePoint)
    XCTAssertNotNil(utility.makeSpec)
    XCTAssertNotNil(utility.makeUrl)
    XCTAssertNotNil(utility.param)
    XCTAssertNotNil(utility.prepareAuth)
    XCTAssertNotNil(utility.prepareBody)
    XCTAssertNotNil(utility.prepareHeaders)
    XCTAssertNotNil(utility.prepareMethod)
    XCTAssertNotNil(utility.prepareParams)
    XCTAssertNotNil(utility.preparePath)
    XCTAssertNotNil(utility.prepareQuery)
    XCTAssertNotNil(utility.resultBasic)
    XCTAssertNotNil(utility.resultBody)
    XCTAssertNotNil(utility.resultHeaders)
    XCTAssertNotNil(utility.transformRequest)
    XCTAssertNotNil(utility.transformResponse)
  }

  func testCleanBasic() {
    let ctx = makeTestCtx(client, utility, nil)
    let val = mapv(("key", .string("secret123")), ("name", .string("test")))
    let cleaned = utility.clean(ctx, val)
    XCTAssertFalse(isNil(cleaned))
  }

  func testDoneBasic() {
    runsection("done") { args in
      let ctx = OmniResolver.omniCtx(args[0], self.client, self.utility)
      return try self.utility.done(ctx)
    }
  }

  func testMakeErrorBasic() {
    runsection("makeError") { args in
      let ctxarg = args.first ?? .map(VMap())
      let ctx = OmniResolver.omniCtx(ctxarg, self.client, self.utility)

      var err: Error? = nil
      if 1 < args.count, let errMap = args[1].asMap {
        err = SdkRunner.errFromMap(errMap)
      }

      return try self.utility.makeError(ctx, err)
    }
  }

  func testMakeErrorNoThrow() throws {
    let ctx = makeTestFullCtx(client, utility)
    ctx.ctrl.throwErr = false
    ctx.result = Result(vm(
      ("ok", .bool(false)),
      ("resdata", .map(vm(("id", .string("safe01")))))
    ))

    let result = try utility.makeError(ctx, ctx.makeError("test_code", "test message"))
    let om = result.asMap
    XCTAssertTrue(om != nil && om!.entries["id"] == .string("safe01"),
      "expected id=safe01, got \(stringify(result))")
  }

  func testFeatureAddBasic() {
    let ctx = makeTestCtx(client, utility, nil)
    let startLen = client.features.count

    let feature = BaseFeature()
    utility.featureAdd(ctx, feature)

    XCTAssertEqual(client.features.count, startLen + 1)
  }

  func testFeatureHookBasic() {
    let hookClient = UnivecSDK.testSDK(nil, nil)
    let hookUtility = hookClient.getUtility()
    let ctx = makeTestCtx(hookClient, hookUtility, nil)

    var called = false
    let hookFeature = TestHookFeature()
    hookFeature.hookFn = { called = true }
    hookClient.features = [hookFeature]

    hookUtility.featureHook(ctx, "TestHook")
    XCTAssertTrue(called, "expected TestHook to be called")
  }

  func testFeatureInitBasic() {
    let initClient = UnivecSDK.testSDK(nil, nil)
    let initUtility = initClient.getUtility()
    let ctx = makeTestCtx(initClient, initUtility, nil)
    ctx.options!.entries["feature"] = .map(vm(
      ("initfeat", .map(vm(("active", .bool(true)))))
    ))

    var initCalled = false
    let feature = TestInitFeature()
    feature.name = "initfeat"
    feature.active = true
    feature.initFn = { initCalled = true }

    initUtility.featureInit(ctx, feature)
    XCTAssertTrue(initCalled, "expected init to be called")
  }

  // THE `extend` SEAM IS REAL. options.extend is the runtime
  // feature-injection seam the README documents, and the constructor reads
  // it - but only after makeOptions' validate, which used to REJECT the key
  // because buildOptSpec never named it. The seam was dead: a caller could
  // not hand in a feature the model did not activate, and every suite that
  // adopts a feature through `extend` passed VACUOUSLY on a client that
  // never held it. Pinned here, in the ungated suite, so the seam is proven
  // whatever features a project selects. Delete the `extend` optspec entry
  // and this goes red.
  func testExtendOptionInstallsAndInitialisesTheFeature() {
    var initCalled = false
    let feature = TestInitFeature()
    feature.name = "extra"
    feature.initFn = { initCalled = true }

    let opts = VMap()
    opts.entries["feature"] = .map(vm(("extra", .map(vm(("active", .bool(true)))))))
    opts.entries["extend"] = .list([.nat(feature)])

    let client = UnivecSDK.testSDK(nil, opts)

    XCTAssertTrue(client.features.contains { $0 === feature },
      "options.extend did not install the feature; installed: "
        + client.features.map { $0.getName() }.joined(separator: ","))
    XCTAssertTrue(initCalled,
      "the extended feature was installed but never initialised")
    XCTAssertFalse(isNil(gp(client.optionsMap(), "extend")),
      "options.extend was validated away by makeOptions")
  }

  func testFeatureInitInactive() {
    let initClient = UnivecSDK.testSDK(nil, nil)
    let initUtility = initClient.getUtility()
    let ctx = makeTestCtx(initClient, initUtility, nil)
    ctx.options!.entries["feature"] = .map(vm(
      ("nofeat", .map(vm(("active", .bool(false)))))
    ))

    var initCalled = false
    let feature = TestInitFeature()
    feature.name = "nofeat"
    feature.active = false
    feature.initFn = { initCalled = true }

    initUtility.featureInit(ctx, feature)
    XCTAssertFalse(initCalled, "expected init NOT to be called for inactive feature")
  }

  func testFetcherLive() throws {
    var calls: [VMap] = []
    let fetch: SystemFetch = { url, fetchdef in
      let c = VMap()
      c.entries["url"] = .string(url)
      c.entries["init"] = .map(fetchdef)
      calls.append(c)
      let r = VMap()
      r.entries["status"] = .int(200)
      r.entries["statusText"] = .string("OK")
      return .map(r)
    }

    let opts = VMap()
    opts.entries["system"] = .map(vm(("fetch", .nat(fetch))))
    let liveClient = UnivecSDK(opts)
    let liveUtility = liveClient.getUtility()
    let ctx = liveUtility.makeContext(
      ["opname": "load", "client": liveClient, "utility": liveUtility], nil)

    let fetchdef = VMap()
    fetchdef.entries["method"] = .string("GET")
    fetchdef.entries["headers"] = .map(VMap())
    _ = try liveUtility.fetcher(ctx, "http://example.com/test", fetchdef)

    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls.first?.entries["url"], .string("http://example.com/test"))
  }

  func testFetcherBlockedTestMode() {
    // Create a live SDK then set mode to test (not using testSDK, which
    // installs the test feature).
    let fetch: SystemFetch = { _, _ in .map(VMap()) }
    let opts = VMap()
    opts.entries["system"] = .map(vm(("fetch", .nat(fetch))))
    let blockedClient = UnivecSDK(opts)
    blockedClient.mode = "test"

    let blockedUtility = blockedClient.getUtility()
    let ctx = blockedUtility.makeContext(
      ["opname": "load", "client": blockedClient, "utility": blockedUtility], nil)

    let fetchdef = VMap()
    fetchdef.entries["method"] = .string("GET")
    fetchdef.entries["headers"] = .map(VMap())

    XCTAssertThrowsError(
      try blockedUtility.fetcher(ctx, "http://example.com/test", fetchdef)
    ) { error in
      XCTAssertTrue(errMessage(error).contains("blocked"),
        "expected 'blocked' in error message, got \(errMessage(error))")
    }
  }

  func testMakeContextBasic() {
    runsection("makeContext") { args in
      guard let inMap = args.first?.asMap else { return .noval }
      let ctx = self.utility.makeContext(self.nativeCtxMap(inMap), nil)
      let result = VMap()
      result.entries["id"] = .string(ctx.id)
      if let op = ctx.op {
        let opm = VMap()
        opm.entries["name"] = .string(op.name)
        opm.entries["input"] = .string(op.input)
        result.entries["op"] = .map(opm)
      }
      return .map(result)
    }
  }

  func testMakeFetchDefBasic() throws {
    let ctx = makeTestFullCtx(client, utility)
    ctx.spec = Spec(vm(
      ("base", .string("http://localhost:8080")),
      ("prefix", .string("/api")),
      ("path", .string("items/{id}")),
      ("suffix", .string("")),
      ("params", .map(vm(("id", .string("item01"))))),
      ("query", .map(VMap())),
      ("headers", .map(vm(("content-type", .string("application/json"))))),
      ("method", .string("GET")),
      ("step", .string("start"))
    ))
    ctx.result = Result(VMap())

    let fetchdef = try utility.makeFetchDef(ctx)
    XCTAssertEqual(fetchdef.entries["method"], .string("GET"))
    let url = fetchdef.entries["url"]?.asString ?? ""
    XCTAssertTrue(url.contains("/api/items/item01"), "expected /api/items/item01 in \(url)")
    XCTAssertEqual(
      fetchdef.entries["headers"]?.asMap?.entries["content-type"],
      .string("application/json"))
    let hasBody = fetchdef.entries["body"].map { !isNil($0) } ?? false
    XCTAssertFalse(hasBody, "expected no body")
  }

  func testMakeFetchDefWithBody() throws {
    let ctx = makeTestFullCtx(client, utility)
    ctx.spec = Spec(vm(
      ("base", .string("http://localhost:8080")),
      ("prefix", .string("")),
      ("path", .string("items")),
      ("suffix", .string("")),
      ("params", .map(VMap())),
      ("query", .map(VMap())),
      ("headers", .map(VMap())),
      ("method", .string("POST")),
      ("step", .string("start")),
      ("body", .map(vm(("name", .string("test")))))
    ))
    ctx.result = Result(VMap())

    let fetchdef = try utility.makeFetchDef(ctx)
    XCTAssertEqual(fetchdef.entries["method"], .string("POST"))
    guard let bodyStr = fetchdef.entries["body"]?.asString else {
      XCTFail("expected string body")
      return
    }
    XCTAssertTrue(bodyStr.contains("\"name\""), "expected \"name\" in \(bodyStr)")
  }

  func testMakeOptionsBasic() {
    runsection("makeOptions") { args in
      let inMap = args.first?.asMap ?? VMap()
      var nctx: [String: Any?] = [:]
      if let o = inMap.entries["options"]?.asMap { nctx["options"] = o }
      if let c = inMap.entries["config"]?.asMap { nctx["config"] = c }
      let ctx = self.utility.makeContext(nctx, nil)
      ctx.client = self.client
      ctx.utility = self.utility
      return .map(self.utility.makeOptions(ctx))
    }
  }

  func testMakeRequestBasic() {
    runsection("makeRequest") { args in
      let ctx = OmniResolver.omniCtx(args[0], self.client, self.utility)
      ctx.options = self.client.optionsMap()

      _ = try self.utility.makeRequest(ctx)

      OmniResolver.omniSyncCtx(args[0], ctx)
      return .noval
    }
  }

  func testMakeResponseBasic() {
    runsection("makeResponse") { args in
      let ctx = OmniResolver.omniCtx(args[0], self.client, self.utility)

      _ = try self.utility.makeResponse(ctx)

      OmniResolver.omniSyncCtx(args[0], ctx)
      return .noval
    }
  }

  func testMakeResultBasic() throws {
    let ctx = makeTestFullCtx(client, utility)
    ctx.spec = Spec(vm(
      ("base", .string("http://localhost:8080")),
      ("prefix", .string("/api")),
      ("path", .string("items/{id}")),
      ("suffix", .string("")),
      ("params", .map(vm(("id", .string("item01"))))),
      ("query", .map(VMap())),
      ("headers", .map(VMap())),
      ("method", .string("GET")),
      ("step", .string("start"))
    ))
    ctx.result = Result(vm(
      ("ok", .bool(true)),
      ("status", .int(200)),
      ("statusText", .string("OK")),
      ("headers", .map(VMap())),
      ("resdata", .map(vm(("id", .string("item01")), ("name", .string("Test")))))
    ))

    let result = try utility.makeResult(ctx)
    XCTAssertEqual(result.status, 200)
  }

  func testMakeResultNoSpec() {
    let ctx = makeTestFullCtx(client, utility)
    ctx.spec = nil
    ctx.result = Result(vm(
      ("ok", .bool(true)),
      ("status", .int(200)),
      ("statusText", .string("OK")),
      ("headers", .map(VMap()))
    ))

    XCTAssertThrowsError(try utility.makeResult(ctx))
  }

  func testMakeResultNoResult() {
    let ctx = makeTestFullCtx(client, utility)
    ctx.spec = Spec(vm(("step", .string("start"))))
    ctx.result = nil

    XCTAssertThrowsError(try utility.makeResult(ctx))
  }

  func testMakeSpecBasic() throws {
    let setupOpts = try setupOptions("makeSpec", "a")
    let specClient = UnivecSDK.testSDK(nil, setupOpts)
    let specUtility = specClient.getUtility()

    runsection("makeSpec") { args in
      let ctx = OmniResolver.omniCtx(args[0], specClient, specUtility)
      ctx.options = specClient.optionsMap()

      _ = try specUtility.makeSpec(ctx)

      OmniResolver.omniSyncCtx(args[0], ctx)
      return .noval
    }
  }

  func testMakePointBasic() throws {
    let ctx = makeTestCtx(client, utility, nil)
    let point = vm(
      ("parts", .list([.string("items"), .string("{id}")])),
      ("args", .map(vm(("params", .list([]))))),
      ("params", .list([])),
      ("alias", .map(VMap())),
      ("select", .map(VMap())),
      ("active", .bool(true)),
      ("transform", .map(VMap()))
    )
    ctx.op!.points = [point]

    _ = try utility.makePoint(ctx)
    XCTAssertNotNil(ctx.point)
  }

  func testMakeUrlBasic() {
    runsection("makeUrl") { args in
      let ctx = OmniResolver.omniCtx(args[0], self.client, self.utility)
      if ctx.result == nil { ctx.result = Result(nil) }
      return .string(try self.utility.makeUrl(ctx))
    }
  }

  func testOperatorBasic() {
    runsection("operator") { args in
      let inMap = args.first?.asMap ?? VMap()
      let op = Operation(inMap)
      let out = VMap()
      out.entries["entity"] = .string(op.entity)
      out.entries["name"] = .string(op.name)
      out.entries["input"] = .string(op.input)
      let pts = VList()
      for p in op.points { pts.items.append(.map(p)) }
      out.entries["points"] = .list(pts)
      return .map(out)
    }
  }

  func testParamBasic() {
    runsection("param") { args in
      guard 2 <= args.count else { return .noval }

      let ctx = OmniResolver.omniCtx(args[0], self.client, self.utility)
      let result = self.utility.param(ctx, args[1])

      OmniResolver.omniSyncCtx(args[0], ctx)
      return result
    }
  }

  func testPrepareAuthBasic() throws {
    let setupOpts = try setupOptions("prepareAuth", "a")
    let authClient = UnivecSDK.testSDK(nil, setupOpts)
    let authUtility = authClient.getUtility()

    runsection("prepareAuth") { args in
      let ctx = OmniResolver.omniCtx(args[0], authClient, authUtility)

      _ = try authUtility.prepareAuth(ctx)

      OmniResolver.omniSyncCtx(args[0], ctx)
      return .noval
    }
  }

  func testPrepareBodyBasic() {
    runsection("prepareBody") { args in
      let ctx = OmniResolver.omniCtx(args[0], self.client, self.utility)
      return self.utility.prepareBody(ctx)
    }
  }

  func testPrepareHeadersBasic() {
    runsection("prepareHeaders") { args in
      let ctx = OmniResolver.omniCtx(args[0], self.client, self.utility)
      return .map(self.utility.prepareHeaders(ctx))
    }
  }

  func testPrepareMethodBasic() {
    runsection("prepareMethod") { args in
      let ctx = OmniResolver.omniCtx(args[0], self.client, self.utility)
      // An op the API does not define resolves NO method: "" is Swift's
      // spelling of that, and the corpus expects a null (the entry for
      // opname "bad" carries no `out`).
      let method = self.utility.prepareMethod(ctx)
      return method.isEmpty ? .noval : .string(method)
    }
  }

  func testPrepareParamsBasic() {
    runsection("prepareParams") { args in
      let ctx = OmniResolver.omniCtx(args[0], self.client, self.utility)
      return .map(self.utility.prepareParams(ctx))
    }
  }

  func testPreparePathBasic() {
    runsection("preparePath") { args in
      let ctx = OmniResolver.omniCtx(args[0], self.client, self.utility)
      return .string(self.utility.preparePath(ctx))
    }
  }

  func testPreparePathSingle() {
    let ctx = makeTestFullCtx(client, utility)
    ctx.point = vm(
      ("parts", .list([.string("items")])),
      ("args", .map(vm(("params", .list([])))))
    )

    let path = utility.preparePath(ctx)
    XCTAssertEqual(path, "items")
  }

  func testPrepareQueryBasic() {
    runsection("prepareQuery") { args in
      let ctx = OmniResolver.omniCtx(args[0], self.client, self.utility)
      return .map(self.utility.prepareQuery(ctx))
    }
  }

  func testResultBasicBasic() {
    runsection("resultBasic") { args in
      let ctx = OmniResolver.omniCtx(args[0], self.client, self.utility)

      let result = self.utility.resultBasic(ctx)

      let res = VMap()
      res.entries["status"] = .int(Int64(result.status))
      res.entries["statusText"] = .string(result.statusText)
      if let err = result.err {
        let em = VMap()
        em.entries["message"] = .string(errMessage(err))
        res.entries["err"] = .map(em)
      }

      return .map(res)
    }
  }

  func testResultBodyBasic() {
    runsection("resultBody") { args in
      let ctx = OmniResolver.omniCtx(args[0], self.client, self.utility)

      _ = self.utility.resultBody(ctx)

      OmniResolver.omniSyncCtx(args[0], ctx)
      return .noval
    }
  }

  func testResultHeadersBasic() {
    runsection("resultHeaders") { args in
      let ctx = OmniResolver.omniCtx(args[0], self.client, self.utility)

      _ = self.utility.resultHeaders(ctx)

      OmniResolver.omniSyncCtx(args[0], ctx)
      return .noval
    }
  }

  func testTransformRequestBasic() {
    runsection("transformRequest") { args in
      let ctx = OmniResolver.omniCtx(args[0], self.client, self.utility)

      let result = self.utility.transformRequest(ctx)

      OmniResolver.omniSyncCtx(args[0], ctx)
      return result
    }
  }

  func testTransformResponseBasic() {
    runsection("transformResponse") { args in
      let ctx = OmniResolver.omniCtx(args[0], self.client, self.utility)

      let result = self.utility.transformResponse(ctx)

      OmniResolver.omniSyncCtx(args[0], ctx)
      return result
    }
  }
}
