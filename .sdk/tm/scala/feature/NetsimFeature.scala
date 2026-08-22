package SCALAPACKAGE.feature

import java.util.{ArrayList, LinkedHashMap, List => JList, Map => JMap}
import java.util.function.Supplier
import SCALAPACKAGE.core.{Context, FetcherFn, SdkClient}

// Network behaviour simulation. Wraps the active transport and injects
// realistic network conditions so offline unit tests can exercise slowness,
// transient failures, rate limiting and outages deterministically.
class NetsimFeature extends BaseFeature("netsim", "0.0.1", true) {

  private var client: SdkClient = null
  private var options: JMap[String, Object] = null
  private var seed: Long = 1

  var calls: Int = 0
  var applied: JList[JMap[String, Object]] = new ArrayList[JMap[String, Object]]()

  override def init(ctx: Context, options: JMap[String, Object]): Unit = {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)

    this.seed = FeatureOptions.foptInt(this.options, "seed", 0).toLong
    if (this.seed == 0) this.seed = 1

    if (!this.active) return

    val inner: FetcherFn = ctx.utility.fetcher
    ctx.utility.fetcher = (ctx2, url, fetchdef) => simulate(ctx2, url, fetchdef, inner)
  }

  private def simulate(ctx: Context, url: String, fetchdef: JMap[String, Object], inner: FetcherFn): Object = {
    val opts = this.options
    this.calls += 1
    val call = this.calls

    val appliedRec = new LinkedHashMap[String, Object]()

    if (FeatureOptions.foptBool(opts, "offline", false)) {
      sleep(pickLatency())
      appliedRec.put("offline", java.lang.Boolean.TRUE)
      track(ctx, appliedRec)
      throw ctx.makeError("netsim_offline", "Simulated network offline (URL was: \"" + url + "\")")
    }

    if (call <= FeatureOptions.foptInt(opts, "errorTimes", 0)) {
      sleep(pickLatency())
      appliedRec.put("error", java.lang.Boolean.TRUE)
      track(ctx, appliedRec)
      throw ctx.makeError("netsim_conn", "Simulated connection error (call " + call + ")")
    }

    if (call <= FeatureOptions.foptInt(opts, "rateLimitTimes", 0)) {
      sleep(pickLatency())
      appliedRec.put("rateLimited", java.lang.Boolean.TRUE)
      track(ctx, appliedRec)
      val extra = new LinkedHashMap[String, Object]()
      extra.put("statusText", "Too Many Requests")
      val headers = new LinkedHashMap[String, Object]()
      headers.put("retry-after", String.valueOf(FeatureOptions.foptInt(opts, "retryAfter", 0)))
      extra.put("headers", headers)
      return respond(429, null, extra)
    }

    val failStatus = FeatureOptions.foptInt(opts, "failStatus", 503)
    val failEvery = FeatureOptions.foptInt(opts, "failEvery", 0)
    val failByCount = call <= FeatureOptions.foptInt(opts, "failTimes", 0)
    val failByEvery = failEvery > 0 && call % failEvery == 0
    val failRate = FeatureOptions.foptNum(opts, "failRate", 0)
    val failByRate = failRate > 0 && rand() < failRate
    if (failByCount || failByEvery || failByRate) {
      sleep(pickLatency())
      appliedRec.put("failStatus", java.lang.Integer.valueOf(failStatus))
      track(ctx, appliedRec)
      val extra = new LinkedHashMap[String, Object]()
      extra.put("statusText", "Simulated Failure")
      return respond(failStatus, null, extra)
    }

    val latency = pickLatency()
    appliedRec.put("latency", java.lang.Integer.valueOf(latency))
    track(ctx, appliedRec)
    sleep(latency)
    inner(ctx, url, fetchdef)
  }

  private def pickLatency(): Int = {
    this.options.get("latency") match {
      case null => 0
      case lm0: JMap[_, _] =>
        val lm = lm0.asInstanceOf[JMap[String, Object]]
        val min = FeatureOptions.foptInt(lm, "min", 0)
        val max = FeatureOptions.foptInt(lm, "max", min)
        if (max <= min) min else min + (rand() * (max - min)).toInt
      case _ =>
        val fixed = FeatureOptions.foptInt(this.options, "latency", 0)
        if (fixed < 0) 0 else fixed
    }
  }

  private def sleep(ms: Int): Unit = {
    if (ms <= 0) return
    FeatureOptions.foptSleep(this.options).accept(ms)
  }

  // Deterministic 0..1 pseudo-random via a linear congruential generator.
  private def rand(): Double = {
    this.seed = (this.seed * 1103515245L + 12345L) & 0x7fffffffL
    this.seed.toDouble / 0x7fffffffL.toDouble
  }

  private def track(ctx: Context, appliedRec: JMap[String, Object]): Unit = {
    this.applied.add(appliedRec)
    if (ctx.ctrl != null && ctx.ctrl.explain != null) {
      val rec = new LinkedHashMap[String, Object]()
      rec.put("calls", java.lang.Integer.valueOf(this.calls))
      rec.put("applied", this.applied)
      ctx.ctrl.explain.put("netsim", rec)
    }
  }

  private def respond(status: Int, data: Object, extra: JMap[String, Object]): JMap[String, Object] = {
    val js: Supplier[Object] = () => data
    val out = new LinkedHashMap[String, Object]()
    out.put("status", java.lang.Integer.valueOf(status))
    out.put("statusText", "OK")
    out.put("json", js)
    out.put("body", "not-used")
    out.put("headers", new LinkedHashMap[String, Object]())
    if (extra != null) out.putAll(extra)
    out
  }
}
