// Network behaviour simulation. Wraps the active transport (the live HTTP
// fetch or the `test` feature's in-memory mock) and injects realistic network
// conditions so offline unit tests can exercise slowness, transient failures,
// rate limiting and outages deterministically.
//
// Every injection mode is counter-driven (per client instance) so tests are
// reproducible without mocking timers. `failRate` adds optional pseudo-random
// failures via a seeded LCG for coverage-style testing.

import Foundation

public final class NetsimFeature: BaseFeature {
  private var client: UnivecSDK?
  private var options: VMap?
  private var seed: Int64 = 0

  // Activity tracking (mirrors the ts client._netsim record).
  public var calls = 0
  public var applied: [VMap] = []

  public override init() {
    super.init()
    version = "0.0.1"
    name = "netsim"
    active = true
  }

  public override func initFeature(_ ctx: Context, _ options: VMap) {
    client = ctx.client
    self.options = options
    active = foptBool(options, "active", false)

    seed = Int64(foptInt(options, "seed", 0))
    if seed == 0 {
      seed = 1
    }

    if !active {
      return
    }

    let inner = ctx.utility!.fetcher!

    ctx.utility!.fetcher = { ctx2, url, fetchdef in
      try self.simulate(ctx2, url, fetchdef, inner)
    }
  }

  private func simulate(_ ctx: Context, _ url: String, _ fetchdef: VMap,
                        _ inner: FetcherFunc) throws -> Value {
    let opts = options
    calls += 1
    let call = calls

    // Record the simulated conditions for test/debug inspection.
    let applied = VMap()

    // Total outage: every call fails at the transport level.
    if foptBool(opts, "offline", false) {
      sleepMs(pickLatency())
      applied.entries["offline"] = .bool(true)
      track(ctx, applied)
      throw ctx.makeError("netsim_offline",
        "Simulated network offline (URL was: \"\(url)\")")
    }

    // Connection-level errors for the first N calls (e.g. ECONNRESET).
    if call <= foptInt(opts, "errorTimes", 0) {
      sleepMs(pickLatency())
      applied.entries["error"] = .bool(true)
      track(ctx, applied)
      throw ctx.makeError("netsim_conn",
        "Simulated connection error (call \(call))")
    }

    // Rate-limit responses (HTTP 429 + Retry-After) for the first N calls.
    if call <= foptInt(opts, "rateLimitTimes", 0) {
      sleepMs(pickLatency())
      applied.entries["rateLimited"] = .bool(true)
      track(ctx, applied)
      let extra = VMap()
      extra.entries["statusText"] = .string("Too Many Requests")
      let headers = VMap()
      headers.entries["retry-after"] = .string(String(foptInt(opts, "retryAfter", 0)))
      extra.entries["headers"] = .map(headers)
      return NetsimFeature.respond(429, .noval, extra)
    }

    // Retryable failure status for the first N calls, or every Nth call,
    // or pseudo-randomly at `failRate`.
    let failStatus = foptInt(opts, "failStatus", 503)
    let failEvery = foptInt(opts, "failEvery", 0)
    let failByCount = call <= foptInt(opts, "failTimes", 0)
    let failByEvery = failEvery > 0 && call % failEvery == 0
    let failRate = foptNum(opts, "failRate", 0)
    let failByRate = failRate > 0 && rand() < failRate
    if failByCount || failByEvery || failByRate {
      sleepMs(pickLatency())
      applied.entries["failStatus"] = .int(Int64(failStatus))
      track(ctx, applied)
      let extra = VMap()
      extra.entries["statusText"] = .string("Simulated Failure")
      return NetsimFeature.respond(failStatus, .noval, extra)
    }

    // Otherwise: apply latency then delegate to the real transport.
    let latency = pickLatency()
    applied.entries["latency"] = .int(Int64(latency))
    track(ctx, applied)
    sleepMs(latency)
    return try inner(ctx, url, fetchdef)
  }

  // PickLatency yields ms: a fixed number, or a uniform sample from {min,max}.
  private func pickLatency() -> Int {
    let l = gp(options, "latency")
    if isNil(l) {
      return 0
    }
    if let lm = l.asMap {
      let mn = foptInt(lm, "min", 0)
      let mx = foptInt(lm, "max", mn)
      if mx <= mn {
        return mn
      }
      return mn + Int(rand() * Double(mx - mn))
    }
    let fixedMs = foptInt(options, "latency", 0)
    return fixedMs < 0 ? 0 : fixedMs
  }

  private func sleepMs(_ ms: Int) {
    if ms <= 0 {
      return
    }
    foptSleep(options)(ms)
  }

  // Rand yields a deterministic 0..1 pseudo-random via a linear congruential
  // generator. `&*`/`&+` avoid overflow traps on the 64-bit accumulator.
  private func rand() -> Double {
    seed = (seed &* 1103515245 &+ 12345) & 0x7fffffff
    return Double(seed) / Double(0x7fffffff)
  }

  private func track(_ ctx: Context, _ applied: VMap) {
    self.applied.append(applied)
    if let explain = ctx.ctrl.explain {
      let obj = VMap()
      obj.entries["calls"] = .int(Int64(calls))
      let list = VList()
      for a in self.applied {
        list.items.append(.map(a))
      }
      obj.entries["applied"] = .list(list)
      explain.entries["netsim"] = .map(obj)
    }
  }

  // Respond builds a transport-shaped response (matching the test feature's
  // mock) that the result pipeline understands.
  private static func respond(_ status: Int, _ data: Value, _ extra: VMap?) -> Value {
    let res = VMap()
    res.entries["status"] = .int(Int64(status))
    res.entries["statusText"] = .string("OK")
    let captured = data
    res.entries["json"] = .nat({ () -> Value in captured } as NativeCall0)
    res.entries["body"] = .string("not-used")
    res.entries["headers"] = .map(VMap())
    if let extra = extra {
      for (k, v) in extra.entries {
        res.entries[k] = v
      }
    }
    return .map(res)
  }
}
