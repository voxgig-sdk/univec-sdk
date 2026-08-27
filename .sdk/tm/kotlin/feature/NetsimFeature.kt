package KOTLINPACKAGE.feature

import java.util.function.Supplier

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.FetcherFn
import KOTLINPACKAGE.core.SdkClient

// Network behaviour simulation. Wraps the active transport and injects
// realistic network conditions so offline unit tests can exercise slowness,
// transient failures, rate limiting and outages deterministically. Every
// injection mode is counter-driven; `failRate` uses a seeded LCG.
@Suppress("UNCHECKED_CAST")
class NetsimFeature : BaseFeature("netsim", "0.0.1", true) {

  private var client: SdkClient? = null
  private var options: MutableMap<String, Any?>? = null
  private var seed = 1L

  // Activity tracking (mirrors the ts client._netsim record).
  var calls = 0
  var applied: MutableList<MutableMap<String, Any?>> = mutableListOf()

  override fun init(ctx: Context, options: MutableMap<String, Any?>) {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)

    this.seed = FeatureOptions.foptInt(this.options, "seed", 0).toLong()
    if (this.seed == 0L) {
      this.seed = 1L
    }

    if (!this.active) {
      return
    }

    val inner: FetcherFn = ctx.utility!!.fetcher

    ctx.utility!!.fetcher = { ctx2, url, fetchdef -> simulate(ctx2, url, fetchdef, inner) }
  }

  private fun simulate(ctx: Context, url: String, fetchdef: MutableMap<String, Any?>, inner: FetcherFn): Any? {
    val opts = this.options
    this.calls++
    val call = this.calls

    // Record the simulated conditions for test/debug inspection.
    val appliedRec = linkedMapOf<String, Any?>()

    // Total outage: every call fails at the transport level.
    if (FeatureOptions.foptBool(opts, "offline", false)) {
      sleep(pickLatency())
      appliedRec["offline"] = true
      track(ctx, appliedRec)
      throw ctx.makeError("netsim_offline", "Simulated network offline (URL was: \"$url\")")
    }

    // Connection-level errors for the first N calls (e.g. ECONNRESET).
    if (call <= FeatureOptions.foptInt(opts, "errorTimes", 0)) {
      sleep(pickLatency())
      appliedRec["error"] = true
      track(ctx, appliedRec)
      throw ctx.makeError("netsim_conn", "Simulated connection error (call $call)")
    }

    // Rate-limit responses (HTTP 429 + Retry-After) for the first N calls.
    if (call <= FeatureOptions.foptInt(opts, "rateLimitTimes", 0)) {
      sleep(pickLatency())
      appliedRec["rateLimited"] = true
      track(ctx, appliedRec)
      val extra = linkedMapOf<String, Any?>()
      extra["statusText"] = "Too Many Requests"
      val headers = linkedMapOf<String, Any?>()
      headers["retry-after"] = FeatureOptions.foptInt(opts, "retryAfter", 0).toString()
      extra["headers"] = headers
      return respond(429, null, extra)
    }

    // Retryable failure status for the first N calls, every Nth call, or
    // pseudo-randomly at `failRate`.
    val failStatus = FeatureOptions.foptInt(opts, "failStatus", 503)
    val failEvery = FeatureOptions.foptInt(opts, "failEvery", 0)
    val failByCount = call <= FeatureOptions.foptInt(opts, "failTimes", 0)
    val failByEvery = failEvery > 0 && call % failEvery == 0
    val failRate = FeatureOptions.foptNum(opts, "failRate", 0.0)
    val failByRate = failRate > 0 && rand() < failRate
    if (failByCount || failByEvery || failByRate) {
      sleep(pickLatency())
      appliedRec["failStatus"] = failStatus
      track(ctx, appliedRec)
      val extra = linkedMapOf<String, Any?>()
      extra["statusText"] = "Simulated Failure"
      return respond(failStatus, null, extra)
    }

    // Otherwise: apply latency then delegate to the real transport.
    val latency = pickLatency()
    appliedRec["latency"] = latency
    track(ctx, appliedRec)
    sleep(latency)
    return inner(ctx, url, fetchdef)
  }

  // pickLatency yields ms: a fixed number, or a uniform sample from {min,max}.
  private fun pickLatency(): Int {
    val l = this.options?.get("latency")
    if (l == null) {
      return 0
    }
    if (l is MutableMap<*, *>) {
      val lm = l as MutableMap<String, Any?>
      val min = FeatureOptions.foptInt(lm, "min", 0)
      val max = FeatureOptions.foptInt(lm, "max", min)
      if (max <= min) {
        return min
      }
      return min + (rand() * (max - min)).toInt()
    }
    val fixed = FeatureOptions.foptInt(this.options, "latency", 0)
    return if (fixed < 0) 0 else fixed
  }

  private fun sleep(ms: Int) {
    if (ms <= 0) {
      return
    }
    FeatureOptions.foptSleep(this.options).accept(ms)
  }

  // rand yields a deterministic 0..1 pseudo-random via a linear congruential
  // generator.
  private fun rand(): Double {
    this.seed = (this.seed * 1103515245L + 12345L) and 0x7fffffffL
    return this.seed.toDouble() / 0x7fffffffL.toDouble()
  }

  private fun track(ctx: Context, appliedRec: MutableMap<String, Any?>) {
    this.applied.add(appliedRec)
    if (ctx.ctrl.explain != null) {
      val rec = linkedMapOf<String, Any?>()
      rec["calls"] = this.calls
      rec["applied"] = this.applied
      ctx.ctrl.explain!!["netsim"] = rec
    }
  }

  // respond builds a transport-shaped response (matching the test feature's
  // mock) that the result pipeline understands.
  private fun respond(status: Int, data: Any?, extra: MutableMap<String, Any?>?): MutableMap<String, Any?> {
    val out = linkedMapOf<String, Any?>()
    out["status"] = status
    out["statusText"] = "OK"
    out["json"] = Supplier<Any?> { data }
    out["body"] = "not-used"
    out["headers"] = linkedMapOf<String, Any?>()
    if (extra != null) {
      out.putAll(extra)
    }
    return out
  }
}
