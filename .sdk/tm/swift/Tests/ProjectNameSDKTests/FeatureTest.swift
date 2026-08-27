// Offline feature-test harness plus behavioural tests for the enterprise
// features (retry, cache, rbac, telemetry, ...). Each feature is driven through
// a faithful miniature of the real operation pipeline against a configurable
// mock transport. Swift twin of the go feature_test.go.

import Foundation
import XCTest

@testable import UnivecSdk

// FhClock: a deterministic virtual clock (now advances only on sleep).
final class FhClock {
  var t: Int64 = 0
  func now() -> Int64 { t }
  func sleep(_ ms: Int) { t += Int64(ms) }
  func advance(_ ms: Int) { t += Int64(ms) }
}

// FhRecorder: a mock transport recording every call.
final class FhRecorder {
  var calls: [VMap] = []
  var reply: ((Int, VMap) -> Value)?

  func fetch(_ ctx: Context, _ url: String, _ fetchdef: VMap) throws -> Value {
    let c = VMap()
    c.entries["url"] = .string(url)
    c.entries["fetchdef"] = .map(fetchdef)
    calls.append(c)
    if let reply = reply { return reply(calls.count, fetchdef) }
    return Fh.response(200, mapv(("ok", .bool(true)), ("n", .int(Int64(calls.count)))), nil)
  }

  func headers(_ i: Int) -> VMap {
    calls[i].entries["fetchdef"]?.asMap?.entries["headers"]?.asMap ?? VMap()
  }
  func fetchdef(_ i: Int) -> VMap { calls[i].entries["fetchdef"]?.asMap ?? VMap() }
  func url(_ i: Int) -> String { calls[i].entries["url"]?.asString ?? "" }
}

struct FhOpSpec {
  var entity = ""
  var op = ""
  var method = ""
  var path = ""
  var query: VMap?
  var headers: VMap?
  var body: Value?
  var ctrl: VMap?
}

struct FhOpResult {
  var ok = false
  var data: Value = .noval
  var err: Error?
  var result: Result?
  var ctx: Context?
}

final class FhHarness {
  var client: UnivecSDK!
  var utility: Utility!
  var rootctx: Context!
  var base = "http://api.test"
  var recorder: FhRecorder?

  private static func defaultMethod(_ op: String) -> String {
    switch op {
    case "create": return "POST"
    case "update": return "PATCH"
    case "remove": return "DELETE"
    default: return "GET"
    }
  }

  private static func buildUrl(_ spec: Spec) -> String {
    let keys = spec.query.entries.filter { !isNil($0.value) }.map { $0.key }.sorted()
    let qs = keys.map {
      escurl(.string($0)) + "=" + escurl(.string(stringify(spec.query.entries[$0]!)))
    }.joined(separator: "&")
    var url = spec.base + spec.path
    if qs != "" { url += "?" + qs }
    return url
  }

  func op(_ o: FhOpSpec) -> FhOpResult {
    let entity = o.entity == "" ? "widget" : o.entity
    let opname = o.op == "" ? "load" : o.op
    let method = o.method == "" ? FhHarness.defaultMethod(opname) : o.method
    let ctrl = o.ctrl ?? VMap()

    let ctx = utility.makeContext(["opname": opname, "ctrl": ctrl], rootctx)
    ctx.op = Operation(vm(("entity", .string(entity)), ("name", .string(opname))))

    utility.featureHook(ctx, "PostConstructEntity")

    utility.featureHook(ctx, "PrePoint")
    if let pointOuter = ctx.out["point"], let pointOut = pointOuter, let perr = pointOut as? Error {
      return fail(ctx, perr)
    }

    utility.featureHook(ctx, "PreSpec")
    let path = o.path == "" ? "/" + entity : o.path
    let headers = VMap()
    if let oh = o.headers { for (k, v) in oh.entries { headers.entries[k] = v } }
    let query = VMap()
    if let oq = o.query { for (k, v) in oq.entries { query.entries[k] = v } }
    let specmap = VMap()
    specmap.entries["method"] = .string(method)
    specmap.entries["base"] = .string(base)
    specmap.entries["path"] = .string(path)
    specmap.entries["headers"] = .map(headers)
    specmap.entries["query"] = .map(query)
    specmap.entries["step"] = .string("start")
    ctx.spec = Spec(specmap)
    if let body = o.body, !isNil(body) { ctx.spec!.body = body }

    utility.featureHook(ctx, "PreRequest")
    ctx.spec!.url = FhHarness.buildUrl(ctx.spec!)

    let fetchdef = VMap()
    fetchdef.entries["url"] = .string(ctx.spec!.url)
    fetchdef.entries["method"] = .string(ctx.spec!.method)
    fetchdef.entries["headers"] = .map(ctx.spec!.headers)
    if !isNil(ctx.spec!.body) { fetchdef.entries["body"] = ctx.spec!.body }

    var response: Value = .noval
    var fetchErr: Error?
    if let reqOuter = ctx.out["request"], let reqOut = reqOuter,
      let canned = reqOut as? Value, !isNil(canned) {
      response = canned
    } else {
      do {
        response = try utility.fetcher(ctx, ctx.spec!.url, fetchdef)
      } catch {
        fetchErr = error
      }
    }
    if let rm = response.asMap { ctx.response = Response(rm) }

    utility.featureHook(ctx, "PreResponse")
    populateResult(ctx, response, fetchErr)
    utility.featureHook(ctx, "PreResult")
    utility.featureHook(ctx, "PreDone")

    if let result = ctx.result, result.ok {
      return FhOpResult(ok: true, data: result.resdata, err: nil, result: result, ctx: ctx)
    }

    let err = ctx.result?.err ?? ctx.makeError("op_failed", "operation failed")
    return fail(ctx, err)
  }

  private func fail(_ ctx: Context, _ err: Error) -> FhOpResult {
    ctx.ctrl.err = err
    utility.featureHook(ctx, "PreUnexpected")
    return FhOpResult(ok: false, data: .noval, err: err, result: ctx.result, ctx: ctx)
  }

  private func populateResult(_ ctx: Context, _ response: Value, _ fetchErr: Error?) {
    let result = Result(nil)
    ctx.result = result
    if let fe = fetchErr { result.err = fe; return }
    guard let rm = response.asMap else {
      result.err = ctx.makeError("request_no_response", "response: undefined")
      return
    }
    let resp = Response(rm)
    result.status = resp.status
    result.statusText = resp.statusText
    if let hm = resp.headers.asMap { result.headers = hm }
    if let jf = resp.jsonFunc { result.body = jf() }
    result.resdata = result.body
    if result.status >= 400 {
      result.err = ctx.makeError("request_status", "request: \(result.status): \(result.statusText)")
    } else if let re = resp.err {
      result.err = re
    }
    if result.err == nil { result.ok = true }
  }
}

enum Fh {
  static func hasFeature(_ name: String) -> Bool {
    gp(SdkConfig.makeConfig(), "feature").asMap?.entries[name] != nil
  }
  static func skipWithout(_ names: String...) -> Bool {
    names.contains { !hasFeature($0) }
  }
  static func errCode(_ e: Error?) -> String { SdkRunner.errCode(e) }

  static func response(_ status: Int, _ data: Value, _ headers: VMap?) -> Value {
    let h = VMap()
    if let headers = headers { for (k, v) in headers.entries { h.entries[k.lowercased()] = v } }
    let m = VMap()
    m.entries["status"] = .int(Int64(status))
    m.entries["statusText"] = .string(status >= 400 ? "ERR" : "OK")
    m.entries["body"] = .string("not-used")
    m.entries["json"] = .nat({ () -> Value in data } as NativeCall0)
    m.entries["headers"] = .map(h)
    return .map(m)
  }

  static func make(_ server: FetcherFunc?, _ features: (BaseFeature, VMap?)...) -> FhHarness {
    let client = UnivecSDK.testSDK(nil, nil)
    client.features = []

    let utility = client.getUtility()
    let h = FhHarness()
    if let server = server {
      utility.fetcher = server
    } else {
      let rec = FhRecorder()
      h.recorder = rec
      utility.fetcher = rec.fetch
    }

    let rootctx = utility.makeContext(["client": client, "utility": utility], client.getRootCtx())

    for (f, options) in features {
      let fopts = VMap()
      fopts.entries["active"] = .bool(true)
      if let options = options { for (k, v) in options.entries { fopts.entries[k] = v } }
      f.initFeature(rootctx, fopts)
      client.features.append(f)
    }

    utility.featureHook(rootctx, "PostConstruct")

    h.client = client
    h.utility = utility
    h.rootctx = rootctx
    return h
  }
}

// --- netsim ------------------------------------------------------------------

final class FeatureNetsimTest: XCTestCase {
  func testFixedLatencyThenDelegate() {
    if Fh.skipWithout("netsim") { return }
    let clock = FhClock()
    let f = NetsimFeature()
    let h = Fh.make(nil, (f, vm(("latency", .int(250)), ("sleep", .nat(clock.sleep)))))
    let res = h.op(FhOpSpec(op: "load", ctrl: vm(("explain", .map(VMap())))))
    XCTAssertTrue(res.ok, "expected ok, got err: \(String(describing: res.err))")
    XCTAssertEqual(clock.t, 250)
    XCTAssertEqual(f.calls, 1)
  }

  func testRangedLatencyInMinMax() {
    if Fh.skipWithout("netsim") { return }
    let clock = FhClock()
    let f = NetsimFeature()
    let h = Fh.make(nil, (f, vm(
      ("latency", .map(vm(("min", .int(100)), ("max", .int(300))))),
      ("seed", .int(7)), ("sleep", .nat(clock.sleep)))))
    _ = h.op(FhOpSpec(op: "load"))
    XCTAssertTrue(clock.t >= 100 && clock.t < 300, "expected latency in [100,300), got \(clock.t)")
  }

  func testEqualMinMaxLatencyExact() {
    if Fh.skipWithout("netsim") { return }
    let clock = FhClock()
    let f = NetsimFeature()
    let h = Fh.make(nil, (f, vm(
      ("latency", .map(vm(("min", .int(50)), ("max", .int(50))))),
      ("sleep", .nat(clock.sleep)))))
    _ = h.op(FhOpSpec(op: "load"))
    XCTAssertEqual(clock.t, 50)
  }

  func testFailTimesReturnsRetryableStatus() {
    if Fh.skipWithout("netsim") { return }
    let f = NetsimFeature()
    let h = Fh.make(nil, (f, vm(("failTimes", .int(2)), ("failStatus", .int(503)))))
    XCTAssertEqual(h.op(FhOpSpec(op: "load")).result!.status, 503)
    XCTAssertEqual(h.op(FhOpSpec(op: "load")).result!.status, 503)
    XCTAssertTrue(h.op(FhOpSpec(op: "load")).ok, "expected third call to succeed")
  }

  func testFailEveryFailsEveryNth() {
    if Fh.skipWithout("netsim") { return }
    let f = NetsimFeature()
    let h = Fh.make(nil, (f, vm(("failEvery", .int(2)))))
    XCTAssertTrue(h.op(FhOpSpec(op: "load")).ok, "call 1 should succeed")
    XCTAssertFalse(h.op(FhOpSpec(op: "load")).ok, "call 2 should fail")
    XCTAssertTrue(h.op(FhOpSpec(op: "load")).ok, "call 3 should succeed")
  }

  func testFailRateWithSeedDeterministic() {
    if Fh.skipWithout("netsim") { return }
    let f = NetsimFeature()
    let h = Fh.make(nil, (f, vm(("failRate", .int(1)), ("seed", .int(5)))))
    XCTAssertFalse(h.op(FhOpSpec(op: "load")).ok, "expected deterministic failure")
  }

  func testErrorTimesConnectionError() {
    if Fh.skipWithout("netsim") { return }
    let f = NetsimFeature()
    let h = Fh.make(nil, (f, vm(("errorTimes", .int(1)))))
    XCTAssertEqual(Fh.errCode(h.op(FhOpSpec(op: "load")).err), "netsim_conn")
  }

  func testOfflineFailsEveryCall() {
    if Fh.skipWithout("netsim") { return }
    let f = NetsimFeature()
    let h = Fh.make(nil, (f, vm(("offline", .bool(true)))))
    XCTAssertEqual(Fh.errCode(h.op(FhOpSpec(op: "load")).err), "netsim_offline")
  }

  func testRateLimitTimes429RetryAfter() {
    if Fh.skipWithout("netsim") { return }
    let f = NetsimFeature()
    let h = Fh.make(nil, (f, vm(("rateLimitTimes", .int(1)), ("retryAfter", .int(3)))))
    let res = h.op(FhOpSpec(op: "load"))
    XCTAssertEqual(res.result!.status, 429)
    XCTAssertEqual(res.result!.headers.entries["retry-after"], .string("3"))
  }

  func testInactiveDoesNotWrap() {
    if Fh.skipWithout("netsim") { return }
    let f = NetsimFeature()
    let h = Fh.make(nil, (f, vm(("active", .bool(false)), ("offline", .bool(true)))))
    let res = h.op(FhOpSpec(op: "load"))
    XCTAssertTrue(res.ok, "inactive netsim must not simulate")
    XCTAssertEqual(f.calls, 0)
  }
}

// --- retry -------------------------------------------------------------------

final class FeatureRetryTest: XCTestCase {
  func testRetriesTransientThenSucceeds() {
    if Fh.skipWithout("retry", "netsim") { return }
    let clock = FhClock()
    let rf = RetryFeature()
    let h = Fh.make(nil,
      (NetsimFeature(), vm(("failTimes", .int(2)), ("failStatus", .int(503)))),
      (rf, vm(("retries", .int(3)), ("minDelay", .int(10)), ("jitter", .bool(false)),
        ("sleep", .nat(clock.sleep)))))
    let res = h.op(FhOpSpec(op: "load"))
    XCTAssertTrue(res.ok, "expected success after retries: \(String(describing: res.err))")
    XCTAssertEqual(rf.attempts, 2)
  }

  func testGivesUpAfterBudget() {
    if Fh.skipWithout("retry", "netsim") { return }
    let clock = FhClock()
    let rf = RetryFeature()
    let h = Fh.make(nil,
      (NetsimFeature(), vm(("failTimes", .int(9)), ("failStatus", .int(500)))),
      (rf, vm(("retries", .int(2)), ("minDelay", .int(1)), ("jitter", .bool(false)),
        ("sleep", .nat(clock.sleep)))))
    XCTAssertEqual(h.op(FhOpSpec(op: "load")).result!.status, 500)
  }

  func testDoesNotRetryNonRetryableStatus() {
    if Fh.skipWithout("retry") { return }
    let rec = FhRecorder()
    rec.reply = { _, _ in Fh.response(404, .noval, nil) }
    let h = Fh.make(rec.fetch, (RetryFeature(), vm(("retries", .int(3)), ("minDelay", .int(0)))))
    _ = h.op(FhOpSpec(op: "load"))
    XCTAssertEqual(rec.calls.count, 1)
  }

  func testRetriesTransportErrorThenReturnsIt() {
    if Fh.skipWithout("retry") { return }
    let clock = FhClock()
    var n = 0
    let server: FetcherFunc = { ctx, _, _ in n += 1; throw ctx.makeError("boom", "boom") }
    let h = Fh.make(server, (RetryFeature(), vm(
      ("retries", .int(2)), ("minDelay", .int(1)), ("jitter", .bool(false)),
      ("sleep", .nat(clock.sleep)))))
    let res = h.op(FhOpSpec(op: "load"))
    XCTAssertFalse(res.ok, "expected failure")
    XCTAssertEqual(n, 3)
  }

  func testRetriesNullTransportResult() {
    if Fh.skipWithout("retry") { return }
    var n = 0
    let server: FetcherFunc = { _, _, _ in
      n += 1
      if n < 2 { return .noval }
      return Fh.response(200, mapv(("ok", .bool(true))), nil)
    }
    let h = Fh.make(server, (RetryFeature(), vm(("retries", .int(3)), ("minDelay", .int(0)))))
    let res = h.op(FhOpSpec(op: "load"))
    XCTAssertTrue(res.ok, "expected success")
    XCTAssertEqual(n, 2)
  }

  func testHonoursServerRetryAfter() {
    if Fh.skipWithout("retry", "netsim") { return }
    let clock = FhClock()
    let h = Fh.make(nil,
      (NetsimFeature(), vm(("rateLimitTimes", .int(1)), ("retryAfter", .int(2)))),
      (RetryFeature(), vm(("retries", .int(2)), ("minDelay", .int(10)), ("maxDelay", .int(60000)),
        ("jitter", .bool(false)), ("sleep", .nat(clock.sleep)))))
    let res = h.op(FhOpSpec(op: "load"))
    XCTAssertTrue(res.ok, "expected success: \(String(describing: res.err))")
    XCTAssertEqual(clock.t, 2000)
  }

  func testInactiveDoesNotWrap() {
    if Fh.skipWithout("retry") { return }
    let rec = FhRecorder()
    rec.reply = { _, _ in Fh.response(503, .noval, nil) }
    let h = Fh.make(rec.fetch, (RetryFeature(), vm(("active", .bool(false)))))
    _ = h.op(FhOpSpec(op: "load"))
    XCTAssertEqual(rec.calls.count, 1)
  }
}

// --- timeout -----------------------------------------------------------------

final class FeatureTimeoutTest: XCTestCase {
  func testSlowRequestTimesOut() {
    if Fh.skipWithout("timeout") { return }
    let server: FetcherFunc = { _, _, _ in
      Thread.sleep(forTimeInterval: 0.06)
      return Fh.response(200, mapv(("ok", .bool(true))), nil)
    }
    let f = TimeoutFeature()
    let h = Fh.make(server, (f, vm(("ms", .int(10)))))
    let res = h.op(FhOpSpec(op: "load"))
    XCTAssertEqual(Fh.errCode(res.err), "timeout")
    XCTAssertEqual(f.count, 1)
  }

  func testFastRequestPasses() {
    if Fh.skipWithout("timeout") { return }
    let h = Fh.make(nil, (TimeoutFeature(), vm(("ms", .int(1000)))))
    XCTAssertTrue(h.op(FhOpSpec(op: "load")).ok)
  }

  func testMsZeroDisables() {
    if Fh.skipWithout("timeout") { return }
    let h = Fh.make(nil, (TimeoutFeature(), vm(("ms", .int(0)))))
    XCTAssertTrue(h.op(FhOpSpec(op: "load")).ok)
  }

  func testInactiveDoesNotWrap() {
    if Fh.skipWithout("timeout") { return }
    let h = Fh.make(nil, (TimeoutFeature(), vm(("active", .bool(false)))))
    XCTAssertTrue(h.op(FhOpSpec(op: "load")).ok)
  }
}

// --- ratelimit ---------------------------------------------------------------

final class FeatureRatelimitTest: XCTestCase {
  func testThrottlesOnceBurstSpent() {
    if Fh.skipWithout("ratelimit") { return }
    let clock = FhClock()
    let f = RatelimitFeature()
    let h = Fh.make(nil, (f, vm(
      ("rate", .int(1)), ("burst", .int(2)),
      ("now", .nat(clock.now)), ("sleep", .nat(clock.sleep)))))
    _ = h.op(FhOpSpec(op: "load"))
    _ = h.op(FhOpSpec(op: "load"))
    _ = h.op(FhOpSpec(op: "load"))
    XCTAssertEqual(f.throttled, 1)
    XCTAssertTrue(clock.t > 0, "expected the clock to advance while throttled")
  }

  func testBurstDefaultsToRateAndRefills() {
    if Fh.skipWithout("ratelimit") { return }
    let clock = FhClock()
    let f = RatelimitFeature()
    let h = Fh.make(nil, (f, vm(
      ("rate", .int(2)), ("now", .nat(clock.now)), ("sleep", .nat(clock.sleep)))))
    _ = h.op(FhOpSpec(op: "load"))
    _ = h.op(FhOpSpec(op: "load"))
    clock.advance(1000)
    _ = h.op(FhOpSpec(op: "load"))
    XCTAssertEqual(f.throttled, 0)
  }

  func testInactiveDoesNotWrap() {
    if Fh.skipWithout("ratelimit") { return }
    let f = RatelimitFeature()
    let h = Fh.make(nil, (f, vm(("active", .bool(false)))))
    XCTAssertTrue(h.op(FhOpSpec(op: "load")).ok)
    XCTAssertEqual(f.throttled, 0)
  }
}

// --- cache -------------------------------------------------------------------

final class FeatureCacheTest: XCTestCase {
  func testServesRepeatedReadFromCache() {
    if Fh.skipWithout("cache") { return }
    let rec = FhRecorder()
    let f = CacheFeature()
    let h = Fh.make(rec.fetch, (f, vm(("ttl", .int(10000)))))
    let a = h.op(FhOpSpec(op: "load", path: "/w/1"))
    let b = h.op(FhOpSpec(op: "load", path: "/w/1"))
    XCTAssertEqual(rec.calls.count, 1)
    XCTAssertTrue(SdkRunner.deepEqual(a.data, b.data), "expected identical cached data")
    XCTAssertEqual(f.hit, 1)
  }

  func testDoesNotCacheNonGet() {
    if Fh.skipWithout("cache") { return }
    let rec = FhRecorder()
    let h = Fh.make(rec.fetch, (CacheFeature(), nil))
    _ = h.op(FhOpSpec(op: "create", path: "/w"))
    _ = h.op(FhOpSpec(op: "create", path: "/w"))
    XCTAssertEqual(rec.calls.count, 2)
  }

  func testDoesNotCacheNon2xx() {
    if Fh.skipWithout("cache") { return }
    let rec = FhRecorder()
    rec.reply = { _, _ in Fh.response(500, .noval, nil) }
    let f = CacheFeature()
    let h = Fh.make(rec.fetch, (f, nil))
    _ = h.op(FhOpSpec(op: "load", path: "/w"))
    _ = h.op(FhOpSpec(op: "load", path: "/w"))
    XCTAssertEqual(rec.calls.count, 2)
    XCTAssertEqual(f.bypass, 2)
  }

  func testRefetchesAfterTtl() {
    if Fh.skipWithout("cache") { return }
    let clock = FhClock()
    let rec = FhRecorder()
    let h = Fh.make(rec.fetch, (CacheFeature(), vm(("ttl", .int(1000)), ("now", .nat(clock.now)))))
    _ = h.op(FhOpSpec(op: "load", path: "/w"))
    clock.advance(1500)
    _ = h.op(FhOpSpec(op: "load", path: "/w"))
    XCTAssertEqual(rec.calls.count, 2)
  }

  func testEvictsOldestPastMax() {
    if Fh.skipWithout("cache") { return }
    let rec = FhRecorder()
    let h = Fh.make(rec.fetch, (CacheFeature(), vm(("ttl", .int(10000)), ("max", .int(1)))))
    _ = h.op(FhOpSpec(op: "load", path: "/a"))
    _ = h.op(FhOpSpec(op: "load", path: "/b"))
    _ = h.op(FhOpSpec(op: "load", path: "/a"))
    XCTAssertEqual(rec.calls.count, 3)
  }

  func testInactiveDoesNotWrap() {
    if Fh.skipWithout("cache") { return }
    let rec = FhRecorder()
    let h = Fh.make(rec.fetch, (CacheFeature(), vm(("active", .bool(false)))))
    _ = h.op(FhOpSpec(op: "load", path: "/x"))
    _ = h.op(FhOpSpec(op: "load", path: "/x"))
    XCTAssertEqual(rec.calls.count, 2)
  }
}

// --- idempotency -------------------------------------------------------------

final class FeatureIdempotencyTest: XCTestCase {
  func testAddsKeyToMutatingOps() {
    if Fh.skipWithout("idempotency") { return }
    let rec = FhRecorder()
    let h = Fh.make(rec.fetch, (IdempotencyFeature(), nil))
    _ = h.op(FhOpSpec(op: "create", path: "/w"))
    XCTAssertNotNil(rec.headers(0).entries["Idempotency-Key"], "expected Idempotency-Key on create")
  }

  func testAddsKeyByHttpMethod() {
    if Fh.skipWithout("idempotency") { return }
    let rec = FhRecorder()
    let h = Fh.make(rec.fetch, (IdempotencyFeature(), nil))
    _ = h.op(FhOpSpec(op: "act", method: "PUT", path: "/w"))
    XCTAssertNotNil(rec.headers(0).entries["Idempotency-Key"], "expected Idempotency-Key on PUT")
  }

  func testLeavesReadsUntouched() {
    if Fh.skipWithout("idempotency") { return }
    let rec = FhRecorder()
    let h = Fh.make(rec.fetch, (IdempotencyFeature(), nil))
    _ = h.op(FhOpSpec(op: "load", path: "/w/1"))
    XCTAssertNil(rec.headers(0).entries["Idempotency-Key"], "expected no key on load")
  }

  func testPreservesCallerKeyCustomHeader() {
    if Fh.skipWithout("idempotency") { return }
    let rec = FhRecorder()
    let h = Fh.make(rec.fetch, (IdempotencyFeature(), vm(("header", .string("X-Idem")))))
    _ = h.op(FhOpSpec(op: "create", path: "/w", headers: vm(("X-Idem", .string("caller-1")))))
    XCTAssertEqual(rec.headers(0).entries["X-Idem"], .string("caller-1"))
  }

  func testInjectedKeygen() {
    if Fh.skipWithout("idempotency") { return }
    let rec = FhRecorder()
    let f = IdempotencyFeature()
    let keygen: () -> String = { "K1" }
    let h = Fh.make(rec.fetch, (f, vm(("keygen", .nat(keygen)))))
    _ = h.op(FhOpSpec(op: "create", path: "/w"))
    XCTAssertEqual(rec.headers(0).entries["Idempotency-Key"], .string("K1"))
    XCTAssertEqual(f.last, "K1")
    XCTAssertEqual(f.issued, 1)
  }

  func testInactiveIsNoop() {
    if Fh.skipWithout("idempotency") { return }
    let rec = FhRecorder()
    let h = Fh.make(rec.fetch, (IdempotencyFeature(), vm(("active", .bool(false)))))
    _ = h.op(FhOpSpec(op: "create", path: "/w"))
    XCTAssertNil(rec.headers(0).entries["Idempotency-Key"], "inactive must not add a key")
  }
}

// --- rbac --------------------------------------------------------------------

final class FeatureRbacTest: XCTestCase {
  func testDeniesBeforeAnyCall() {
    if Fh.skipWithout("rbac") { return }
    let rec = FhRecorder()
    let f = RbacFeature()
    let h = Fh.make(rec.fetch, (f, vm(
      ("rules", .map(vm(("widget.remove", .string("admin"))))),
      ("permissions", .list([])))))
    let res = h.op(FhOpSpec(op: "remove", path: "/w/1"))
    XCTAssertEqual(Fh.errCode(res.err), "rbac_denied")
    XCTAssertEqual(rec.calls.count, 0)
    XCTAssertEqual(f.denied, 1)
  }

  func testAllowsHeldPermission() {
    if Fh.skipWithout("rbac") { return }
    let h = Fh.make(nil, (RbacFeature(), vm(
      ("rules", .map(vm(("widget.remove", .string("admin"))))),
      ("permissions", .list([.string("admin")])))))
    XCTAssertTrue(h.op(FhOpSpec(op: "remove", path: "/w/1")).ok)
  }

  func testOpRuleAndWildcardGrant() {
    if Fh.skipWithout("rbac") { return }
    let h = Fh.make(nil, (RbacFeature(), vm(
      ("rules", .map(vm(("load", .string("read"))))),
      ("permissions", .list([.string("*")])))))
    XCTAssertTrue(h.op(FhOpSpec(op: "load")).ok)
  }

  func testDefaultAllowAndDenyTrue() {
    if Fh.skipWithout("rbac") { return }
    let allow = Fh.make(nil, (RbacFeature(), vm(("permissions", .list([])))))
    XCTAssertTrue(allow.op(FhOpSpec(op: "load")).ok, "expected default allow")

    let deny = Fh.make(nil, (RbacFeature(), vm(("deny", .bool(true)), ("permissions", .list([])))))
    XCTAssertEqual(Fh.errCode(deny.op(FhOpSpec(op: "load")).err), "rbac_denied")
  }

  func testInactiveIsNoop() {
    if Fh.skipWithout("rbac") { return }
    let h = Fh.make(nil, (RbacFeature(), vm(("active", .bool(false)), ("deny", .bool(true)))))
    XCTAssertTrue(h.op(FhOpSpec(op: "load")).ok, "inactive rbac must not deny")
  }
}

// --- metrics -----------------------------------------------------------------

final class FeatureMetricsTest: XCTestCase {
  func testCountsOkAndErrPerOp() {
    if Fh.skipWithout("metrics", "netsim") { return }
    let f = MetricsFeature()
    let h = Fh.make(nil,
      (NetsimFeature(), vm(("failTimes", .int(1)), ("failStatus", .int(500)))),
      (f, nil))
    _ = h.op(FhOpSpec(op: "load"))
    _ = h.op(FhOpSpec(op: "load"))
    _ = h.op(FhOpSpec(op: "list"))
    XCTAssertTrue(f.total.count == 3 && f.total.ok == 2 && f.total.err == 1,
      "expected total 3/2/1, got \(f.total.count)/\(f.total.ok)/\(f.total.err)")
    XCTAssertTrue(f.ops["widget.load"]?.count == 2, "expected widget.load count 2")
  }

  func testInjectedClock() {
    if Fh.skipWithout("metrics") { return }
    let clock = FhClock()
    let f = MetricsFeature()
    let h = Fh.make(nil, (f, vm(("now", .nat(clock.now)))))
    _ = h.op(FhOpSpec(op: "load"))
    XCTAssertEqual(f.total.count, 1)
    XCTAssertEqual(f.total.totalMs, 0)
  }

  func testInactiveRecordsNothing() {
    if Fh.skipWithout("metrics") { return }
    let f = MetricsFeature()
    let h = Fh.make(nil, (f, vm(("active", .bool(false)))))
    _ = h.op(FhOpSpec(op: "load"))
    XCTAssertEqual(f.total.count, 0)
  }
}

// --- telemetry ---------------------------------------------------------------

final class FeatureTelemetryTest: XCTestCase {
  func testOpensSpansAndPropagatesHeaders() {
    if Fh.skipWithout("telemetry") { return }
    let rec = FhRecorder()
    var exported: [VMap] = []
    let exporter: (VMap) -> Void = { exported.append($0) }
    let f = TelemetryFeature()
    let h = Fh.make(rec.fetch, (f, vm(("exporter", .nat(exporter)))))
    let res = h.op(FhOpSpec(op: "load"))
    XCTAssertTrue(res.ok, "expected success")
    XCTAssertTrue(f.spans.count == 1 && exported.count == 1,
      "expected 1 span + 1 export, got \(f.spans.count)/\(exported.count)")
    let sent = rec.headers(0)
    XCTAssertEqual(f.spans[0].entries["traceId"], sent.entries["X-Trace-Id"])
    let traceparent = sent.entries["traceparent"]?.asString ?? ""
    XCTAssertTrue(SdkRunner.matchString("/^00-.+-.+-01$/", traceparent), "traceparent: \(traceparent)")
  }

  func testRecordsFailedSpan() {
    if Fh.skipWithout("telemetry", "netsim") { return }
    let f = TelemetryFeature()
    let h = Fh.make(nil,
      (NetsimFeature(), vm(("failTimes", .int(1)), ("failStatus", .int(500)))),
      (f, nil))
    _ = h.op(FhOpSpec(op: "load"))
    XCTAssertTrue(f.spans.count == 1 && f.spans[0].entries["ok"] == .bool(false), "expected 1 failed span")
  }

  func testInjectedIdgenAndClock() {
    if Fh.skipWithout("telemetry") { return }
    let clock = FhClock()
    let f = TelemetryFeature()
    let idgen: (String) -> String = { kind in kind + "-X" }
    let h = Fh.make(nil, (f, vm(("idgen", .nat(idgen)), ("now", .nat(clock.now)))))
    _ = h.op(FhOpSpec(op: "load"))
    XCTAssertEqual(f.spans[0].entries["traceId"], .string("trace-X"))
    XCTAssertEqual(f.spans[0].entries["durationMs"], .int(0))
  }

  func testInactiveRecordsNothing() {
    if Fh.skipWithout("telemetry") { return }
    let f = TelemetryFeature()
    let h = Fh.make(nil, (f, vm(("active", .bool(false)))))
    _ = h.op(FhOpSpec(op: "load"))
    XCTAssertEqual(f.spans.count, 0)
  }
}

// --- debug -------------------------------------------------------------------

final class FeatureDebugTest: XCTestCase {
  func testRedactsAndHonoursOnentryMax() {
    if Fh.skipWithout("debug") { return }
    var seen: [VMap] = []
    let onEntry: (VMap) -> Void = { seen.append($0) }
    let f = DebugFeature()
    let h = Fh.make(nil, (f, vm(("max", .int(1)), ("onEntry", .nat(onEntry)))))
    _ = h.op(FhOpSpec(op: "load", headers: vm(("authorization", .string("Bearer secret")))))
    _ = h.op(FhOpSpec(op: "list"))
    XCTAssertEqual(f.entries.count, 1)
    XCTAssertEqual(seen.count, 2)
    let headers = seen[0].entries["headers"]?.asMap
    XCTAssertEqual(headers?.entries["authorization"], .string("<redacted>"))
  }

  func testCapturesFailures() {
    if Fh.skipWithout("debug", "netsim") { return }
    let f = DebugFeature()
    let h = Fh.make(nil,
      (NetsimFeature(), vm(("failTimes", .int(1)), ("failStatus", .int(500)))),
      (f, nil))
    _ = h.op(FhOpSpec(op: "load"))
    XCTAssertTrue(f.entries.count == 1 && f.entries[0].entries["ok"] == .bool(false), "expected 1 failed entry")
  }

  func testInjectedClockAndCustomRedact() {
    if Fh.skipWithout("debug") { return }
    let clock = FhClock()
    let f = DebugFeature()
    let h = Fh.make(nil, (f, vm(("now", .nat(clock.now)), ("redact", .list([.string("x-secret")])))))
    _ = h.op(FhOpSpec(op: "load", headers: vm(("x-secret", .string("hide")), ("x-ok", .string("show")))))
    let headers = f.entries[0].entries["headers"]?.asMap
    XCTAssertEqual(headers?.entries["x-secret"], .string("<redacted>"))
    XCTAssertEqual(headers?.entries["x-ok"], .string("show"))
  }

  func testInactiveRecordsNothing() {
    if Fh.skipWithout("debug") { return }
    let f = DebugFeature()
    let h = Fh.make(nil, (f, vm(("active", .bool(false)))))
    _ = h.op(FhOpSpec(op: "load"))
    XCTAssertEqual(f.entries.count, 0)
  }
}

// --- audit -------------------------------------------------------------------

final class FeatureAuditTest: XCTestCase {
  func testOneRecordPerOpSinkActor() {
    if Fh.skipWithout("audit", "netsim") { return }
    var sunk: [VMap] = []
    let sink: (VMap) -> Void = { sunk.append($0) }
    let f = AuditFeature()
    let h = Fh.make(nil,
      (NetsimFeature(), vm(("failTimes", .int(1)), ("failStatus", .int(500)))),
      (f, vm(("actor", .string("svc")), ("max", .int(5)), ("sink", .nat(sink)))))
    _ = h.op(FhOpSpec(op: "remove", path: "/w/1"))
    _ = h.op(FhOpSpec(op: "load", ctrl: vm(("actor", .string("per-call")))))
    XCTAssertEqual(f.records.count, 2)
    XCTAssertEqual(f.records[0].entries["outcome"], .string("error"))
    XCTAssertEqual(f.records[0].entries["actor"], .string("svc"))
    XCTAssertEqual(f.records[1].entries["actor"], .string("per-call"))
    XCTAssertEqual(sunk.count, 2)
  }

  func testDefaultActorAnonymous() {
    if Fh.skipWithout("audit") { return }
    let f = AuditFeature()
    let h = Fh.make(nil, (f, nil))
    _ = h.op(FhOpSpec(op: "load"))
    XCTAssertEqual(f.records[0].entries["actor"], .string("anonymous"))
  }

  func testInjectedClock() {
    if Fh.skipWithout("audit") { return }
    let f = AuditFeature()
    let nowFn: () -> Int64 = { 42 }
    let h = Fh.make(nil, (f, vm(("now", .nat(nowFn)))))
    _ = h.op(FhOpSpec(op: "load"))
    XCTAssertEqual(f.records[0].entries["ts"], .int(42))
  }

  func testInactiveRecordsNothing() {
    if Fh.skipWithout("audit") { return }
    let f = AuditFeature()
    let h = Fh.make(nil, (f, vm(("active", .bool(false)))))
    _ = h.op(FhOpSpec(op: "load"))
    XCTAssertEqual(f.records.count, 0)
  }
}

// --- clienttrack -------------------------------------------------------------

final class FeatureClienttrackTest: XCTestCase {
  func testStableClientIdUniqueRequestIdsUa() {
    if Fh.skipWithout("clienttrack") { return }
    let rec = FhRecorder()
    let f = ClienttrackFeature()
    let h = Fh.make(rec.fetch, (f, vm(("clientName", .string("Acme")), ("clientVersion", .string("2.0.0")))))
    _ = h.op(FhOpSpec(op: "load"))
    _ = h.op(FhOpSpec(op: "load"))
    let h0 = rec.headers(0)
    let h1 = rec.headers(1)
    XCTAssertEqual(h0.entries["User-Agent"], .string("Acme/2.0.0"))
    XCTAssertEqual(h0.entries["X-Client-Id"], h1.entries["X-Client-Id"])
    XCTAssertNotEqual(h0.entries["X-Request-Id"], h1.entries["X-Request-Id"])
    XCTAssertEqual(f.requests, 2)
  }

  func testDoesNotClobberCallerUa() {
    if Fh.skipWithout("clienttrack") { return }
    let rec = FhRecorder()
    let h = Fh.make(rec.fetch, (ClienttrackFeature(), nil))
    _ = h.op(FhOpSpec(op: "load", headers: vm(("User-Agent", .string("mine")))))
    XCTAssertEqual(rec.headers(0).entries["User-Agent"], .string("mine"))
  }

  func testInjectedIdgenFixedSession() {
    if Fh.skipWithout("clienttrack") { return }
    let rec = FhRecorder()
    let idgen: (String) -> String = { kind in kind + "-1" }
    let h = Fh.make(rec.fetch, (ClienttrackFeature(), vm(
      ("sessionId", .string("S1")), ("idgen", .nat(idgen)))))
    _ = h.op(FhOpSpec(op: "load"))
    XCTAssertEqual(rec.headers(0).entries["X-Client-Id"], .string("S1"))
    XCTAssertEqual(rec.headers(0).entries["X-Request-Id"], .string("request-1"))
  }

  func testInactiveStampsNothing() {
    if Fh.skipWithout("clienttrack") { return }
    let rec = FhRecorder()
    let h = Fh.make(rec.fetch, (ClienttrackFeature(), vm(("active", .bool(false)))))
    _ = h.op(FhOpSpec(op: "load"))
    XCTAssertNil(rec.headers(0).entries["X-Client-Id"], "inactive must not stamp headers")
  }
}

// --- paging ------------------------------------------------------------------

final class FeaturePagingTest: XCTestCase {
  func testStampsPageLimitAndReadsHeaders() {
    if Fh.skipWithout("paging") { return }
    let rec = FhRecorder()
    rec.reply = { _, _ in
      Fh.response(200, mapv(("items", .list([.int(1), .int(2)]))), vm(
        ("x-next-page", .string("2")), ("x-total-count", .string("5")),
        ("link", .string("</w?page=2>; rel=\"next\""))))
    }
    let f = PagingFeature()
    let h = Fh.make(rec.fetch, (f, vm(("limit", .int(2)))))
    let res = h.op(FhOpSpec(op: "list", path: "/w"))
    XCTAssertTrue(rec.url(0).contains("page=1"))
    XCTAssertTrue(rec.url(0).contains("limit=2"))
    let paging = res.result!.paging!
    XCTAssertEqual(toInt(gp(paging, "nextPage")), 2)
    XCTAssertEqual(toInt(gp(paging, "totalCount")), 5)
    XCTAssertEqual(paging.entries["next"], .string("/w?page=2"))
  }

  func testBodyCursorAndExplicitCursor() {
    if Fh.skipWithout("paging") { return }
    let rec = FhRecorder()
    rec.reply = { _, _ in
      Fh.response(200, mapv(("nextCursor", .string("abc")), ("hasMore", .bool(true))), nil)
    }
    let h = Fh.make(rec.fetch, (PagingFeature(), nil))
    let res = h.op(FhOpSpec(op: "list", path: "/w",
      ctrl: vm(("paging", .map(vm(("cursor", .string("xyz"))))))))
    XCTAssertTrue(rec.url(0).contains("cursor=xyz"))
    XCTAssertEqual(res.result!.paging!.entries["cursor"], .string("abc"))
    XCTAssertEqual(res.result!.paging!.entries["hasMore"], .bool(true))
  }

  func testNonListNotPaged() {
    if Fh.skipWithout("paging") { return }
    let rec = FhRecorder()
    let h = Fh.make(rec.fetch, (PagingFeature(), nil))
    _ = h.op(FhOpSpec(op: "load", path: "/w/1"))
    XCTAssertFalse(rec.url(0).contains("page="))
  }

  func testInactiveStampsNothing() {
    if Fh.skipWithout("paging") { return }
    let rec = FhRecorder()
    let h = Fh.make(rec.fetch, (PagingFeature(), vm(("active", .bool(false)))))
    _ = h.op(FhOpSpec(op: "list", path: "/w"))
    XCTAssertFalse(rec.url(0).contains("page="))
  }
}

// --- streaming ---------------------------------------------------------------

final class FeatureStreamingTest: XCTestCase {
  func testStreamsListItems() {
    if Fh.skipWithout("streaming") { return }
    let clock = FhClock()
    let rec = FhRecorder()
    rec.reply = { _, _ in Fh.response(200, .list([.string("a"), .string("b"), .string("c")]), nil) }
    let h = Fh.make(rec.fetch, (StreamingFeature(), vm(("chunkDelay", .int(5)), ("sleep", .nat(clock.sleep)))))
    let res = h.op(FhOpSpec(op: "list", path: "/w"))
    XCTAssertTrue(res.result!.streaming, "expected streaming result")
    let seen = res.result!.stream!()
    XCTAssertTrue(SdkRunner.deepEqual(.list(seen), .list([.string("a"), .string("b"), .string("c")])))
    XCTAssertEqual(clock.t, 15)
  }

  func testBatchesWithChunksize() {
    if Fh.skipWithout("streaming") { return }
    let rec = FhRecorder()
    rec.reply = { _, _ in Fh.response(200, .list([.int(1), .int(2), .int(3), .int(4), .int(5)]), nil) }
    let h = Fh.make(rec.fetch, (StreamingFeature(), vm(("chunkSize", .int(2)))))
    let res = h.op(FhOpSpec(op: "list", path: "/w"))
    let batches = res.result!.stream!()
    let want: Value = .list([
      .list([.int(1), .int(2)]), .list([.int(3), .int(4)]), .list([.int(5)]),
    ])
    XCTAssertTrue(SdkRunner.deepEqual(.list(batches), want))
  }

  func testNonListNotStreamed() {
    if Fh.skipWithout("streaming") { return }
    let h = Fh.make(nil, (StreamingFeature(), nil))
    let res = h.op(FhOpSpec(op: "load"))
    XCTAssertFalse(res.result!.streaming || res.result!.stream != nil, "expected no stream on non-list op")
  }

  func testInactiveIsNoop() {
    if Fh.skipWithout("streaming") { return }
    let f = StreamingFeature()
    let h = Fh.make(nil, (f, vm(("active", .bool(false)))))
    let res = h.op(FhOpSpec(op: "list", path: "/w"))
    XCTAssertFalse(res.result!.streaming, "inactive streaming must not attach")
    XCTAssertEqual(f.opened, 0)
  }
}

// --- proxy -------------------------------------------------------------------

final class FeatureProxyTest: XCTestCase {
  func testRoutesThroughProxy() {
    if Fh.skipWithout("proxy") { return }
    let rec = FhRecorder()
    let f = ProxyFeature()
    let h = Fh.make(rec.fetch, (f, vm(("url", .string("http://proxy:8080")))))
    _ = h.op(FhOpSpec(op: "load"))
    XCTAssertEqual(rec.fetchdef(0).entries["proxy"], .string("http://proxy:8080"))
    XCTAssertEqual(f.routed, 1)
  }

  func testBypassesNoproxyHosts() {
    if Fh.skipWithout("proxy") { return }
    let rec = FhRecorder()
    let h = Fh.make(rec.fetch, (ProxyFeature(), vm(
      ("url", .string("http://proxy:8080")), ("noProxy", .list([.string("api.test")])))))
    _ = h.op(FhOpSpec(op: "load"))
    XCTAssertNil(rec.fetchdef(0).entries["proxy"], "expected noProxy bypass")
  }

  func testFromenvReadsHttpsProxy() {
    if Fh.skipWithout("proxy") { return }
    let prev = ProcessInfo.processInfo.environment["HTTPS_PROXY"]
    setenv("HTTPS_PROXY", "http://env-proxy:8080", 1)
    defer { if let prev = prev { setenv("HTTPS_PROXY", prev, 1) } else { unsetenv("HTTPS_PROXY") } }
    let rec = FhRecorder()
    let h = Fh.make(rec.fetch, (ProxyFeature(), vm(("fromEnv", .bool(true)))))
    _ = h.op(FhOpSpec(op: "load"))
    XCTAssertEqual(rec.fetchdef(0).entries["proxy"], .string("http://env-proxy:8080"))
  }

  func testNoUrlIsNoop() {
    if Fh.skipWithout("proxy") { return }
    let rec = FhRecorder()
    let h = Fh.make(rec.fetch, (ProxyFeature(), nil))
    _ = h.op(FhOpSpec(op: "load"))
    XCTAssertNil(rec.fetchdef(0).entries["proxy"], "expected no proxy annotation")
  }

  func testInactiveDoesNotWrap() {
    if Fh.skipWithout("proxy") { return }
    let rec = FhRecorder()
    let h = Fh.make(rec.fetch, (ProxyFeature(), vm(("active", .bool(false)), ("url", .string("http://proxy:8080")))))
    _ = h.op(FhOpSpec(op: "load"))
    XCTAssertNil(rec.fetchdef(0).entries["proxy"], "inactive proxy must not route")
  }
}

// --- composition -------------------------------------------------------------

final class FeatureCompositionTest: XCTestCase {
  func testCacheHitSkipsSimulatedFailure() {
    if Fh.skipWithout("cache", "netsim") { return }
    let nf = NetsimFeature()
    let h = Fh.make(nil,
      (nf, vm(("failEvery", .int(2)))),
      (CacheFeature(), vm(("ttl", .int(10000)))))
    let first = h.op(FhOpSpec(op: "load", path: "/w"))
    XCTAssertTrue(first.ok, "first load should succeed")
    let second = h.op(FhOpSpec(op: "load", path: "/w"))
    XCTAssertTrue(second.ok, "second load should hit the cache")
    XCTAssertEqual(nf.calls, 1)
  }
}
