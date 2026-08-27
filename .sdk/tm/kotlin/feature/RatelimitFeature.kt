package KOTLINPACKAGE.feature

import kotlin.math.ceil
import kotlin.math.min

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.FetcherFn
import KOTLINPACKAGE.core.SdkClient

// Client-side rate limiting via a token bucket. Each request consumes a
// token; when the bucket is empty the request waits until the bucket refills
// at `rate` tokens per second (with capacity `burst`, default: rate). The
// clock (`now`) and the wait (`sleep`) are injectable for deterministic tests.
class RatelimitFeature : BaseFeature("ratelimit", "0.0.1", true) {

  private var client: SdkClient? = null
  private var options: MutableMap<String, Any?>? = null
  private var tokens = 0.0
  private var last = 0L

  // Activity tracking (mirrors the ts client._ratelimit record).
  var throttled = 0
  var waitMs = 0

  override fun init(ctx: Context, options: MutableMap<String, Any?>) {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)

    if (!this.active) {
      return
    }

    val rate = FeatureOptions.foptNum(this.options, "rate", 5.0)
    val burst = FeatureOptions.foptNum(this.options, "burst", rate)
    this.tokens = burst
    this.last = FeatureOptions.foptNow(this.options).getAsLong()

    val inner: FetcherFn = ctx.utility!!.fetcher

    ctx.utility!!.fetcher = { ctx2, url, fetchdef ->
      acquire()
      inner(ctx2, url, fetchdef)
    }
  }

  private fun acquire() {
    val rate = FeatureOptions.foptNum(this.options, "rate", 5.0)
    val burst = FeatureOptions.foptNum(this.options, "burst", rate)

    // Refill according to elapsed time.
    val now = FeatureOptions.foptNow(this.options).getAsLong()
    val elapsed = now - this.last
    this.last = now
    this.tokens = min(burst, this.tokens + (elapsed / 1000.0) * rate)

    if (this.tokens >= 1) {
      this.tokens -= 1
      return
    }

    // Not enough tokens: wait for one to accrue, then consume it.
    val needed = 1 - this.tokens
    val wait = ceil((needed / rate) * 1000).toInt()
    track(wait)
    if (wait > 0) {
      FeatureOptions.foptSleep(this.options).accept(wait)
    }
    this.last = FeatureOptions.foptNow(this.options).getAsLong()
    this.tokens = 0.0
  }

  private fun track(wait: Int) {
    this.throttled++
    this.waitMs += wait
  }
}
