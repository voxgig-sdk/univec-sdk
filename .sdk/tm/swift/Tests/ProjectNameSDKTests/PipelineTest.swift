// Direct unit tests for the operation-pipeline utilities: the error and edge
// branches (missing spec/response/result, 4xx handling, transport failures,
// featureAdd ordering, auth header shaping) a normal success-path op never
// reaches. API-agnostic. Swift twin of the go pipeline_test.go.

import XCTest

@testable import UnivecSdk

final class PipelineTest: XCTestCase {
  // --- helpers ------------------------------------------------------------

  private func plClient(_ sdkopts: VMap?) -> (UnivecSDK, Utility) {
    let client = UnivecSDK.testSDK(nil, sdkopts)
    return (client, client.getUtility())
  }

  private func plCtx(_ client: UnivecSDK, _ utility: Utility, _ ctrl: VMap?) -> Context {
    var ctxmap: [String: Any?] = ["opname": "load", "client": client, "utility": utility]
    if let ctrl = ctrl { ctxmap["ctrl"] = ctrl }
    return utility.makeContext(ctxmap, client.getRootCtx())
  }

  private func errCode(_ act: () throws -> Void) -> String {
    do { try act(); return "" } catch let e as UnivecError { return e.code } catch { return "" }
  }

  private func plResponse(_ status: Int, _ data: Value, _ headers: VMap?) -> VMap {
    let h = VMap()
    if let headers = headers {
      for (k, v) in headers.entries { h.entries[k.lowercased()] = v }
    }
    let m = VMap()
    m.entries["status"] = .int(Int64(status))
    m.entries["statusText"] = .string(status >= 400 ? "ERR" : "OK")
    m.entries["body"] = .string("not-used")
    m.entries["json"] = .nat({ () -> Value in data } as NativeCall0)
    m.entries["headers"] = .map(h)
    return m
  }

  // --- feature order (PR #2) ----------------------------------------------

  // resolveOpts runs makeOptions over an options.feature value (map or list)
  // and returns the derived options so __derived__.featureorder can be
  // asserted.
  private func resolveOpts(_ feature: Value) -> VMap {
    let (client, utility) = plClient(nil)
    let options = VMap()
    options.entries["feature"] = feature
    let cfg = VMap()
    cfg.entries["options"] = .map(VMap())
    let ctxmap: [String: Any?] = [
      "client": client, "utility": utility, "options": options, "config": cfg,
    ]
    let ctx = utility.makeContext(ctxmap, client.getRootCtx())
    return utility.makeOptions(ctx)
  }

  private func featureOrder(_ opts: VMap) -> String {
    guard let list = gpath(opts, "__derived__", "featureorder").asList else { return "" }
    return list.items.map { $0.asString ?? "" }.joined(separator: ",")
  }

  func testFeatureOrderMapIsTestFirst() {
    let feature = vm(
      ("metrics", .map(vm(("active", .bool(true))))),
      ("test", .map(vm(("active", .bool(true))))))
    XCTAssertEqual(featureOrder(resolveOpts(.map(feature))), "test,metrics")
  }

  func testFeatureOrderArrayPreservesExplicitOrder() {
    let e1 = vm(("name", .string("metrics")), ("active", .bool(true)))
    let e2 = vm(("name", .string("test")), ("active", .bool(true)))
    let o = resolveOpts(.list(VList([.map(e1), .map(e2)])))
    XCTAssertEqual(featureOrder(o), "metrics,test")
    // The list is normalized to a map for merge/init; opts are preserved.
    XCTAssertEqual(gpath(o, "feature", "metrics", "active"), .bool(true))
    XCTAssertEqual(gpath(o, "feature", "test", "active"), .bool(true))
  }

  func testFeatureOrderMapNoTestIsSorted() {
    let feature = vm(
      ("retry", .map(vm(("active", .bool(true))))),
      ("cache", .map(vm(("active", .bool(true))))))
    XCTAssertEqual(featureOrder(resolveOpts(.map(feature))), "cache,retry")
  }

  // PlEntity is a minimal fake entity for the list-wrap test.
  final class PlEntity: Entity {
    let nm: String
    let made: VList
    init(_ name: String, _ made: VList) { nm = name; self.made = made }
    func getName() -> String { nm }
    func make() -> Entity { PlEntity(nm, made) }
    func data(_ newdata: Value?) -> Value {
      if let nd = newdata, !isNil(nd) { made.items.append(nd) }
      return .noval
    }
    func matchv(_ newmatch: Value?) -> Value { .noval }
  }

  // --- MakeResponse -------------------------------------------------------

  func testMakeResponseGuardsMissingSpecResponseResult() {
    let (client, utility) = plClient(nil)

    var ctx = plCtx(client, utility, nil)
    ctx.spec = nil
    ctx.response = Response(VMap())
    ctx.result = Result(nil)
    XCTAssertEqual(errCode { _ = try utility.makeResponse(ctx) }, "response_no_spec")

    ctx = plCtx(client, utility, nil)
    ctx.spec = Spec(vm(("step", .string("s"))))
    ctx.response = nil
    ctx.result = Result(nil)
    XCTAssertEqual(errCode { _ = try utility.makeResponse(ctx) }, "response_no_response")

    ctx = plCtx(client, utility, nil)
    ctx.spec = Spec(vm(("step", .string("s"))))
    ctx.response = Response(VMap())
    ctx.result = nil
    XCTAssertEqual(errCode { _ = try utility.makeResponse(ctx) }, "response_no_result")
  }

  func testMakeResponse4xxSetsResultErrAndCopiesHeaders() {
    let (client, utility) = plClient(nil)
    let ctx = plCtx(client, utility, nil)
    ctx.spec = Spec(vm(("step", .string("s"))))
    ctx.response = Response(plResponse(404, .noval, vm(("x-a", .string("1")))))
    ctx.result = Result(nil)
    _ = try? utility.makeResponse(ctx)
    XCTAssertNotNil(ctx.result!.err)
    XCTAssertEqual(ctx.result!.status, 404)
    XCTAssertEqual(ctx.result!.headers.entries["x-a"], .string("1"))
  }

  func testMakeResponse2xxParsesBodyAndMarksOk() {
    let (client, utility) = plClient(nil)
    let ctx = plCtx(client, utility, nil)
    ctx.spec = Spec(vm(("step", .string("s"))))
    ctx.response = Response(plResponse(200, .map(vm(("v", .int(1)))), nil))
    ctx.result = Result(nil)
    _ = try? utility.makeResponse(ctx)
    XCTAssertTrue(ctx.result!.ok)
    XCTAssertEqual(ctx.result!.body.asMap?.entries["v"], .int(1))
  }

  func testMakeResponseRecordsToCtrlExplain() {
    let (client, utility) = plClient(nil)
    let ctx = plCtx(client, utility, vm(("explain", .map(VMap()))))
    ctx.spec = Spec(vm(("step", .string("s"))))
    ctx.response = Response(plResponse(200, .map(vm(("v", .int(2)))), nil))
    ctx.result = Result(nil)
    _ = try? utility.makeResponse(ctx)
    XCTAssertNotNil(ctx.ctrl.explain?.entries["result"])
  }

  // --- MakeResult ----------------------------------------------------------

  func testMakeResultGuardsMissingSpecResult() {
    let (client, utility) = plClient(nil)

    var ctx = plCtx(client, utility, nil)
    ctx.spec = nil
    ctx.result = Result(nil)
    XCTAssertEqual(errCode { _ = try utility.makeResult(ctx) }, "result_no_spec")

    ctx = plCtx(client, utility, nil)
    ctx.spec = Spec(vm(("step", .string("s"))))
    ctx.result = nil
    XCTAssertEqual(errCode { _ = try utility.makeResult(ctx) }, "result_no_result")
  }

  func testMakeResultListOpWrapsResdataIntoEntities() {
    let (client, utility) = plClient(nil)
    let made = VList()
    let ctx = plCtx(client, utility, nil)
    ctx.op = Operation(vm(("entity", .string("x")), ("name", .string("list"))))
    ctx.entity = PlEntity("x", made)
    ctx.spec = Spec(vm(("step", .string("s"))))
    ctx.result = Result(vm(("resdata",
      .list([.map(vm(("a", .int(1)))), .map(vm(("a", .int(2))))]))))
    let result = try! utility.makeResult(ctx)
    XCTAssertEqual(result.resdata.asList?.items.count, 2)
    XCTAssertEqual(made.items.count, 2)
  }

  func testMakeResultEmptyListYieldsEmptyResdata() {
    let (client, utility) = plClient(nil)
    let made = VList()
    let ctx = plCtx(client, utility, nil)
    ctx.op = Operation(vm(("entity", .string("x")), ("name", .string("list"))))
    ctx.entity = PlEntity("x", made)
    ctx.spec = Spec(vm(("step", .string("s"))))
    ctx.result = Result(vm(("resdata", .list([]))))
    let result = try! utility.makeResult(ctx)
    XCTAssertEqual(result.resdata.asList?.items.count, 0)
  }

  // --- MakeRequest ----------------------------------------------------------

  private func utilWith(_ client: UnivecSDK, _ fetcher: @escaping FetcherFunc) -> Utility {
    let u = client.getUtility()
    u.fetcher = fetcher
    return u
  }

  private func reqSpec() -> Spec {
    return Spec(vm(
      ("base", .string("http://h")), ("path", .string("a")), ("method", .string("GET")),
      ("headers", .map(VMap())), ("step", .string("s"))))
  }

  func testMakeRequestGuardsMissingSpec() {
    let (client, _) = plClient(nil)
    let utility = utilWith(client) { _, _, _ in .map(self.plResponse(200, .noval, nil)) }
    let ctx = plCtx(client, utility, nil)
    ctx.spec = nil
    XCTAssertEqual(errCode { _ = try utility.makeRequest(ctx) }, "request_no_spec")
  }

  func testMakeRequestTransportErrorCarriedOnResponse() {
    let (client, _) = plClient(nil)
    let utility = utilWith(client) { ctx2, _, _ in throw ctx2.makeError("boom", "boom") }
    let ctx = plCtx(client, utility, nil)
    ctx.spec = reqSpec()
    let resp = try! utility.makeRequest(ctx)
    XCTAssertEqual((resp.err as? UnivecError)?.code, "boom")
  }

  func testMakeRequestNullTransportResultBecomesResponseError() {
    let (client, _) = plClient(nil)
    let utility = utilWith(client) { _, _, _ in .noval }
    let ctx = plCtx(client, utility, nil)
    ctx.spec = reqSpec()
    let resp = try! utility.makeRequest(ctx)
    XCTAssertNotNil(resp.err)
  }

  func testMakeRequestNormalTransportResponseWrapped() {
    let (client, _) = plClient(nil)
    let utility = utilWith(client) { _, _, _ in .map(self.plResponse(200, .map(vm(("a", .int(1)))), nil)) }
    let ctx = plCtx(client, utility, nil)
    ctx.spec = reqSpec()
    let resp = try! utility.makeRequest(ctx)
    XCTAssertEqual(resp.status, 200)
  }

  func testMakeRequestRecordsFetchdefToCtrlExplain() {
    let (client, _) = plClient(nil)
    let utility = utilWith(client) { _, _, _ in .map(self.plResponse(200, .noval, nil)) }
    let ctx = plCtx(client, utility, vm(("explain", .map(VMap()))))
    ctx.spec = reqSpec()
    _ = try! utility.makeRequest(ctx)
    XCTAssertNotNil(ctx.ctrl.explain?.entries["fetchdef"])
  }

  // --- Done / MakeError -------------------------------------------------------

  func testDoneReturnsResdataOnSuccess() {
    let (client, utility) = plClient(nil)
    let ctx = plCtx(client, utility, nil)
    ctx.result = Result(vm(("ok", .bool(true)), ("resdata", .map(vm(("id", .string("i1")))))))
    let result = try! utility.done(ctx)
    XCTAssertEqual(result.asMap?.entries["id"], .string("i1"))
  }

  func testDoneErrorsWhenNotOk() {
    let (client, utility) = plClient(nil)
    let ctx = plCtx(client, utility, nil)
    ctx.result = Result(vm(("ok", .bool(false))))
    XCTAssertThrowsError(try utility.done(ctx))
  }

  func testMakeErrorReturnsResdataWhenThrowFalse() {
    let (client, utility) = plClient(nil)
    let ctx = plCtx(client, utility, nil)
    ctx.ctrl.throwErr = false
    ctx.result = Result(vm(("ok", .bool(false)), ("resdata", .string("fallback"))))
    let result = try! utility.makeError(ctx, ctx.makeError("test_code", "test message"))
    XCTAssertEqual(result, .string("fallback"))
  }

  func testMakeErrorRecordsToCtrlExplain() {
    let (client, utility) = plClient(nil)
    let ctx = plCtx(client, utility, vm(("explain", .map(VMap()))))
    ctx.ctrl.throwErr = false
    ctx.result = Result(vm(("ok", .bool(false))))
    _ = try! utility.makeError(ctx, ctx.makeError("x", "x"))
    XCTAssertNotNil(ctx.ctrl.explain?.entries["err"])
  }

  // --- FeatureAdd ----------------------------------------------------------

  func testFeatureAddAppendsByDefault() {
    let (client, utility) = plClient(nil)
    let ctx = plCtx(client, utility, nil)
    let start = client.features.count
    let f = BaseFeature()
    utility.featureAdd(ctx, f)
    XCTAssertEqual(client.features.count, start + 1)
    XCTAssertTrue(client.features.last === f)
  }

  func testFeatureAddOrderingBeforeAfterReplace() {
    func named(_ name: String) -> BaseFeature {
      let f = BaseFeature(); f.name = name; return f
    }

    let (client, utility) = plClient(nil)
    let ctx = plCtx(client, utility, nil)
    client.features = []

    func names() -> String { client.features.map { $0.getName() }.joined(separator: ",") }

    utility.featureAdd(ctx, named("a"))
    utility.featureAdd(ctx, named("b"))
    XCTAssertEqual(names(), "a,b")

    let before = named("z1"); before.addOpts = vm(("__before__", .string("b")))
    utility.featureAdd(ctx, before)
    XCTAssertEqual(names(), "a,z1,b")

    let after = named("z2"); after.addOpts = vm(("__after__", .string("a")))
    utility.featureAdd(ctx, after)
    XCTAssertEqual(names(), "a,z2,z1,b")

    let repl = named("z3"); repl.addOpts = vm(("__replace__", .string("z1")))
    utility.featureAdd(ctx, repl)
    XCTAssertEqual(names(), "a,z2,z3,b")

    let miss = named("z4"); miss.addOpts = vm(("__before__", .string("missing")))
    utility.featureAdd(ctx, miss)
    XCTAssertEqual(names(), "a,z2,z3,b,z4")
  }

  // --- PrepareAuth ----------------------------------------------------------

  private func authSpec(_ headers: VMap?) -> Spec {
    return Spec(vm(("headers", .map(headers ?? VMap())), ("step", .string("s"))))
  }

  func testPrepareAuthGuardsMissingSpec() {
    let (client, utility) = plClient(vm(("apikey", .string("K"))))
    let ctx = plCtx(client, utility, nil)
    ctx.spec = nil
    XCTAssertEqual(errCode { _ = try utility.prepareAuth(ctx) }, "auth_no_spec")
  }

  func testPrepareAuthApikeyWithPrefixSpaceJoined() {
    let (client, utility) = plClient(vm(
      ("apikey", .string("K")), ("auth", .map(vm(("prefix", .string("Bearer")))))))
    let ctx = plCtx(client, utility, nil)
    ctx.spec = authSpec(nil)
    _ = try! utility.prepareAuth(ctx)
    XCTAssertEqual(ctx.spec!.headers.entries["authorization"], .string("Bearer K"))
  }

  func testPrepareAuthRawApikeyEmptyPrefixAsIs() {
    let (client, utility) = plClient(vm(
      ("apikey", .string("K")), ("auth", .map(vm(("prefix", .string("")))))))
    let ctx = plCtx(client, utility, nil)
    ctx.spec = authSpec(nil)
    _ = try! utility.prepareAuth(ctx)
    XCTAssertEqual(ctx.spec!.headers.entries["authorization"], .string("K"))
  }

  func testPrepareAuthEmptyApikeyDropsHeader() {
    let (client, utility) = plClient(vm(
      ("apikey", .string("")), ("auth", .map(vm(("prefix", .string("Bearer")))))))
    let ctx = plCtx(client, utility, nil)
    ctx.spec = authSpec(vm(("authorization", .string("stale"))))
    _ = try! utility.prepareAuth(ctx)
    XCTAssertNil(ctx.spec!.headers.entries["authorization"])
  }

  func testPrepareAuthMissingApikeyDropsHeader() {
    let (client, utility) = plClient(vm(("auth", .map(vm(("prefix", .string("Bearer")))))))
    let options = client.optionsMap()
    if let apikey = options.entries["apikey"]?.asString, apikey != "" { return }
    let ctx = plCtx(client, utility, nil)
    ctx.spec = authSpec(vm(("authorization", .string("stale"))))
    _ = try! utility.prepareAuth(ctx)
    XCTAssertNil(ctx.spec!.headers.entries["authorization"])
  }

  func testPrepareAuthPublicApiNoAuthBlockDropsHeader() {
    let (client, utility) = plClient(vm(("apikey", .string("K"))))
    let options = client.optionsMap()
    if let auth = options.entries["auth"], !isNil(auth) { return }
    let ctx = plCtx(client, utility, nil)
    ctx.spec = authSpec(vm(("authorization", .string("stale"))))
    _ = try! utility.prepareAuth(ctx)
    XCTAssertNil(ctx.spec!.headers.entries["authorization"])
  }
}
