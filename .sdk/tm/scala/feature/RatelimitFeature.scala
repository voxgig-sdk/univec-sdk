package SCALAPACKAGE.feature

import java.util.{Map => JMap}
import SCALAPACKAGE.core.{Context, FetcherFn, SdkClient}

// Client-side rate limiting via a token bucket.
class RatelimitFeature extends BaseFeature("ratelimit", "0.0.1", true) {

  private var client: SdkClient = null
  private var options: JMap[String, Object] = null
  private var tokens: Double = 0
  private var last: Long = 0

  var throttled: Int = 0
  var waitMs: Int = 0

  override def init(ctx: Context, options: JMap[String, Object]): Unit = {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)
    if (!this.active) return

    val rate = FeatureOptions.foptNum(this.options, "rate", 5)
    val burst = FeatureOptions.foptNum(this.options, "burst", rate)
    this.tokens = burst
    this.last = FeatureOptions.foptNow(this.options).getAsLong()

    val inner: FetcherFn = ctx.utility.fetcher
    ctx.utility.fetcher = (ctx2, url, fetchdef) => { acquire(); inner(ctx2, url, fetchdef) }
  }

  private def acquire(): Unit = {
    val rate = FeatureOptions.foptNum(this.options, "rate", 5)
    val burst = FeatureOptions.foptNum(this.options, "burst", rate)

    val now = FeatureOptions.foptNow(this.options).getAsLong()
    val elapsed = now - this.last
    this.last = now
    this.tokens = Math.min(burst, this.tokens + (elapsed / 1000.0) * rate)

    if (this.tokens >= 1) {
      this.tokens -= 1
      return
    }

    val needed = 1 - this.tokens
    val wait = Math.ceil((needed / rate) * 1000).toInt
    track(wait)
    if (wait > 0) FeatureOptions.foptSleep(this.options).accept(wait)
    this.last = FeatureOptions.foptNow(this.options).getAsLong()
    this.tokens = 0
  }

  private def track(wait: Int): Unit = {
    this.throttled += 1
    this.waitMs += wait
  }
}
