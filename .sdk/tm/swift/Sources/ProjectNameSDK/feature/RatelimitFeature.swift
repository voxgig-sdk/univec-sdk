// Client-side rate limiting via a token bucket. Each request consumes a
// token; when the bucket is empty the request waits until the bucket refills
// at `rate` tokens per second (with capacity `burst`, default: rate). This
// keeps the client under a server's published quota rather than discovering
// it via 429s. The clock (`now`) and the wait (`sleep`) are injectable so the
// accounting can be tested deterministically.

import Foundation

public final class RatelimitFeature: BaseFeature {
  private var client: UnivecSDK?
  private var options: VMap?
  private var tokens: Double = 0
  private var last: Int64 = 0

  // Activity tracking (mirrors the ts client._ratelimit record).
  public var throttled = 0
  public var waitMs = 0

  public override init() {
    super.init()
    version = "0.0.1"
    name = "ratelimit"
    active = true
  }

  public override func initFeature(_ ctx: Context, _ options: VMap) {
    client = ctx.client
    self.options = options
    active = foptBool(options, "active", false)

    if !active {
      return
    }

    let rate = foptNum(options, "rate", 5)
    let burst = foptNum(options, "burst", rate)
    tokens = burst
    last = foptNow(options)()

    let inner = ctx.utility!.fetcher!

    ctx.utility!.fetcher = { ctx2, url, fetchdef in
      self.acquire()
      return try inner(ctx2, url, fetchdef)
    }
  }

  private func acquire() {
    let rate = foptNum(options, "rate", 5)
    let burst = foptNum(options, "burst", rate)

    // Refill according to elapsed time.
    let now = foptNow(options)()
    let elapsed = now - last
    last = now
    tokens = min(burst, tokens + (Double(elapsed) / 1000.0) * rate)

    if tokens >= 1 {
      tokens -= 1
      return
    }

    // Not enough tokens: wait for one to accrue, then consume it.
    let needed = 1 - tokens
    let wait = Int(ceil((needed / rate) * 1000))
    track(wait)
    if wait > 0 {
      foptSleep(options)(wait)
    }
    last = foptNow(options)()
    tokens = 0
  }

  private func track(_ wait: Int) {
    throttled += 1
    waitMs += wait
  }
}
