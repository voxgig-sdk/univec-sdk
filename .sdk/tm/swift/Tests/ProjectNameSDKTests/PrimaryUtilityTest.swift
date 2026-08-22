// Primary utility test suite - drives every utility on the client utility
// object, partly via the shared corpus in ../../.sdk/test/test.json
// ("primary" section) and partly via direct checks. Swift twin of
// tm/csharp/test/PrimaryUtilityTest.cs and tm/go/test/primary_utility_test.go.

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
  // XCTestCase has no custom init; set these up per test.
  private var primary: Value!
  private var client: UnivecSDK!
  private var utility: Utility!

  override func setUp() {
    super.setUp()
    primary = SdkRunner.loadPrimary()
    client = UnivecSDK.testSDK(nil, nil)
    utility = client.getUtility()
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
    SdkRunner.runSet(SdkRunner.spec(primary, "done", "basic")) { entry in
      let ctxmap = entry.entries["ctx"]?.asMap
      let ctx = SdkRunner.makeCtxFromMap(ctxmap, self.client, self.utility)
      SdkRunner.fixCtx(ctx, self.client)
      return try self.utility.done(ctx)
    }
  }

  func testMakeErrorBasic() {
    SdkRunner.runSet(SdkRunner.spec(primary, "makeError", "basic")) { entry in
      var argsList = entry.entries["args"]?.asList
      if argsList == nil || argsList!.items.isEmpty {
        let l = VList()
        l.items.append(.map(VMap()))
        argsList = l
      }
      let args = argsList!

      let ctxmap = args.items[0].asMap ?? VMap()
      let ctx = SdkRunner.makeCtxFromMap(ctxmap, self.client, self.utility)
      SdkRunner.fixCtx(ctx, self.client)

      var err: Error? = nil
      if args.items.count > 1, let errMap = args.items[1].asMap {
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
    SdkRunner.runSet(SdkRunner.spec(primary, "makeContext", "basic")) { entry in
      guard let inMap = entry.entries["in"]?.asMap else { return .noval }
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
    SdkRunner.runSet(SdkRunner.spec(primary, "makeOptions", "basic")) { entry in
      let inMap = entry.entries["in"]?.asMap ?? VMap()
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
    SdkRunner.runSet(SdkRunner.spec(primary, "makeRequest", "basic")) { entry in
      let ctxmap = entry.entries["ctx"]?.asMap
      let ctx = SdkRunner.makeCtxFromMap(ctxmap, self.client, self.utility)
      ctx.options = self.client.optionsMap()

      _ = try self.utility.makeRequest(ctx)

      // Update entry ctx for match checking.
      if let ctxmap = ctxmap {
        if ctx.response != nil { ctxmap.entries["response"] = .string("exists") }
        if ctx.result != nil { ctxmap.entries["result"] = .string("exists") }
      }

      return .noval
    }
  }

  func testMakeResponseBasic() {
    SdkRunner.runSet(SdkRunner.spec(primary, "makeResponse", "basic")) { entry in
      let ctxmap = entry.entries["ctx"]?.asMap
      let ctx = SdkRunner.makeCtxFromMap(ctxmap, self.client, self.utility)
      SdkRunner.fixCtx(ctx, self.client)

      _ = try self.utility.makeResponse(ctx)

      // Update entry ctx for match checking with result data.
      if let ctxmap = ctxmap, let result = ctx.result {
        let rm = VMap()
        rm.entries["ok"] = .bool(result.ok)
        rm.entries["status"] = .int(Int64(result.status))
        rm.entries["statusText"] = .string(result.statusText)
        rm.entries["headers"] = .map(result.headers)
        rm.entries["body"] = result.body
        ctxmap.entries["result"] = .map(rm)
      }

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

  func testMakeSpecBasic() {
    let setupOpts = SdkRunner.spec(primary, "makeSpec", "DEF", "setup", "a").asMap
    let specClient = UnivecSDK.testSDK(nil, setupOpts)
    let specUtility = specClient.getUtility()

    SdkRunner.runSet(SdkRunner.spec(primary, "makeSpec", "basic")) { entry in
      let ctxmap = entry.entries["ctx"]?.asMap
      let ctx = SdkRunner.makeCtxFromMap(ctxmap, specClient, specUtility)
      ctx.options = specClient.optionsMap()

      _ = try self.utility.makeSpec(ctx)

      // Update entry ctx for match.
      if let ctxmap = ctxmap, let spec = ctx.spec {
        let sm = VMap()
        sm.entries["base"] = .string(spec.base)
        sm.entries["prefix"] = .string(spec.prefix)
        sm.entries["suffix"] = .string(spec.suffix)
        sm.entries["method"] = .string(spec.method)
        sm.entries["params"] = .map(spec.params)
        sm.entries["query"] = .map(spec.query)
        sm.entries["headers"] = .map(spec.headers)
        sm.entries["step"] = .string(spec.step)
        ctxmap.entries["spec"] = .map(sm)
      }

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
    SdkRunner.runSet(SdkRunner.spec(primary, "makeUrl", "basic")) { entry in
      let ctxmap = entry.entries["ctx"]?.asMap
      let ctx = SdkRunner.makeCtxFromMap(ctxmap, self.client, self.utility)
      if ctx.result == nil { ctx.result = Result(nil) }
      return .string(try self.utility.makeUrl(ctx))
    }
  }

  func testOperatorBasic() {
    SdkRunner.runSet(SdkRunner.spec(primary, "operator", "basic")) { entry in
      let inMap = entry.entries["in"]?.asMap ?? VMap()
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
    SdkRunner.runSet(SdkRunner.spec(primary, "param", "basic")) { entry in
      guard let args = entry.entries["args"]?.asList, args.items.count >= 2 else {
        return .noval
      }

      let ctxmap = args.items[0].asMap ?? VMap()
      let ctx = SdkRunner.makeCtxFromMap(ctxmap, self.client, self.utility)
      let paramdef = args.items[1]

      let result = self.utility.param(ctx, paramdef)

      // Copy spec alias back to entry ctx for matching.
      if let matchSpec = entry.entries["match"]?.asMap,
        let ctxMatch = matchSpec.entries["ctx"]?.asMap,
        let specMatch = ctxMatch.entries["spec"]?.asMap,
        specMatch.entries["alias"] != nil,
        let spec = ctx.spec
      {
        let aliasHolder = VMap()
        aliasHolder.entries["alias"] = .map(spec.alias)
        if let entryCtx = entry.entries["ctx"]?.asMap {
          entryCtx.entries["spec"] = .map(aliasHolder)
        } else {
          let newCtx = VMap()
          newCtx.entries["spec"] = .map(aliasHolder)
          entry.entries["ctx"] = .map(newCtx)
        }
      }

      return result
    }
  }

  func testPrepareAuthBasic() {
    let setupOpts = SdkRunner.spec(primary, "prepareAuth", "DEF", "setup", "a").asMap
    let authClient = UnivecSDK.testSDK(nil, setupOpts)
    let authUtility = authClient.getUtility()

    SdkRunner.runSet(SdkRunner.spec(primary, "prepareAuth", "basic")) { entry in
      let ctxmap = entry.entries["ctx"]?.asMap
      let ctx = SdkRunner.makeCtxFromMap(ctxmap, authClient, authUtility)
      SdkRunner.fixCtx(ctx, authClient)

      _ = try self.utility.prepareAuth(ctx)

      // Update entry ctx for match.
      if let ctxmap = ctxmap, let spec = ctx.spec {
        let sm = VMap()
        sm.entries["headers"] = .map(spec.headers)
        ctxmap.entries["spec"] = .map(sm)
      }

      return .noval
    }
  }

  func testPrepareBodyBasic() {
    SdkRunner.runSet(SdkRunner.spec(primary, "prepareBody", "basic")) { entry in
      let ctxmap = entry.entries["ctx"]?.asMap
      let ctx = SdkRunner.makeCtxFromMap(ctxmap, self.client, self.utility)
      SdkRunner.fixCtx(ctx, self.client)
      return self.utility.prepareBody(ctx)
    }
  }

  func testPrepareHeadersBasic() {
    SdkRunner.runSet(SdkRunner.spec(primary, "prepareHeaders", "basic")) { entry in
      let ctxmap = entry.entries["ctx"]?.asMap
      let ctx = SdkRunner.makeCtxFromMap(ctxmap, self.client, self.utility)
      return .map(self.utility.prepareHeaders(ctx))
    }
  }

  func testPrepareMethodBasic() {
    SdkRunner.runSet(SdkRunner.spec(primary, "prepareMethod", "basic")) { entry in
      let ctxmap = entry.entries["ctx"]?.asMap
      let ctx = SdkRunner.makeCtxFromMap(ctxmap, self.client, self.utility)
      return .string(self.utility.prepareMethod(ctx))
    }
  }

  func testPrepareParamsBasic() {
    SdkRunner.runSet(SdkRunner.spec(primary, "prepareParams", "basic")) { entry in
      let ctxmap = entry.entries["ctx"]?.asMap
      let ctx = SdkRunner.makeCtxFromMap(ctxmap, self.client, self.utility)
      return .map(self.utility.prepareParams(ctx))
    }
  }

  func testPreparePathBasic() {
    // Was hand-written cases that had drifted out of the shared corpus
    // (the preparePath fixture shipped as an empty `set: []`).
    SdkRunner.runSet(SdkRunner.spec(primary, "preparePath", "basic")) { entry in
      let ctxmap = entry.entries["ctx"]?.asMap
      let ctx = SdkRunner.makeCtxFromMap(ctxmap, self.client, self.utility)
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
    SdkRunner.runSet(SdkRunner.spec(primary, "prepareQuery", "basic")) { entry in
      let ctxmap = entry.entries["ctx"]?.asMap
      let ctx = SdkRunner.makeCtxFromMap(ctxmap, self.client, self.utility)
      return .map(self.utility.prepareQuery(ctx))
    }
  }

  func testResultBasicBasic() {
    SdkRunner.runSet(SdkRunner.spec(primary, "resultBasic", "basic")) { entry in
      let ctxmap = entry.entries["ctx"]?.asMap
      let ctx = SdkRunner.makeCtxFromMap(ctxmap, self.client, self.utility)
      SdkRunner.fixCtx(ctx, self.client)

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
    SdkRunner.runSet(SdkRunner.spec(primary, "resultBody", "basic")) { entry in
      let ctxmap = entry.entries["ctx"]?.asMap
      let ctx = SdkRunner.makeCtxFromMap(ctxmap, self.client, self.utility)

      _ = self.utility.resultBody(ctx)

      if let ctxmap = ctxmap, let result = ctx.result {
        let rm = VMap()
        rm.entries["body"] = result.body
        ctxmap.entries["result"] = .map(rm)
      }

      return .noval
    }
  }

  func testResultHeadersBasic() {
    SdkRunner.runSet(SdkRunner.spec(primary, "resultHeaders", "basic")) { entry in
      let ctxmap = entry.entries["ctx"]?.asMap
      let ctx = SdkRunner.makeCtxFromMap(ctxmap, self.client, self.utility)

      _ = self.utility.resultHeaders(ctx)

      if let ctxmap = ctxmap, let result = ctx.result {
        let rm = VMap()
        rm.entries["headers"] = .map(result.headers)
        ctxmap.entries["result"] = .map(rm)
      }

      return .noval
    }
  }

  func testTransformRequestBasic() {
    SdkRunner.runSet(SdkRunner.spec(primary, "transformRequest", "basic")) { entry in
      let ctxmap = entry.entries["ctx"]?.asMap
      let ctx = SdkRunner.makeCtxFromMap(ctxmap, self.client, self.utility)

      let result = self.utility.transformRequest(ctx)

      // Update entry ctx for match (step changed).
      if let ctxmap = ctxmap, let spec = ctx.spec,
        let specMap = ctxmap.entries["spec"]?.asMap
      {
        specMap.entries["step"] = .string(spec.step)
      }

      return result
    }
  }

  func testTransformResponseBasic() {
    SdkRunner.runSet(SdkRunner.spec(primary, "transformResponse", "basic")) { entry in
      let ctxmap = entry.entries["ctx"]?.asMap
      let ctx = SdkRunner.makeCtxFromMap(ctxmap, self.client, self.utility)

      let result = self.utility.transformResponse(ctx)

      if let ctxmap = ctxmap, let spec = ctx.spec,
        let specMap = ctxmap.entries["spec"]?.asMap
      {
        specMap.entries["step"] = .string(spec.step)
      }

      return result
    }
  }
}
