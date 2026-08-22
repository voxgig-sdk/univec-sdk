package SCALAPACKAGE.feature

import java.util.{ArrayList, LinkedHashMap, List => JList, Map => JMap}
import java.util.concurrent.ThreadLocalRandom
import SCALAPACKAGE.core.{Context, FetcherFn, SdkClient}

// Automatic retry of transient failures with exponential backoff and jitter.
class RetryFeature extends BaseFeature("retry", "0.0.1", true) {

  private var client: SdkClient = null
  private var options: JMap[String, Object] = null

  var attempts: Int = 0
  var retries: JList[JMap[String, Object]] = new ArrayList[JMap[String, Object]]()

  override def init(ctx: Context, options: JMap[String, Object]): Unit = {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)
    if (!this.active) return

    val inner: FetcherFn = ctx.utility.fetcher
    ctx.utility.fetcher = (ctx2, url, fetchdef) => withRetry(ctx2, url, fetchdef, inner)
  }

  private def withRetry(ctx: Context, url: String, fetchdef: JMap[String, Object], inner: FetcherFn): Object = {
    val max = FeatureOptions.foptInt(this.options, "retries", 2)
    val minDelay = FeatureOptions.foptInt(this.options, "minDelay", 50)
    val maxDelay = FeatureOptions.foptInt(this.options, "maxDelay", 2000)
    val factor = FeatureOptions.foptNum(this.options, "factor", 2)

    var attempt = 0
    while (true) {
      var res: Object = null
      var err: RuntimeException = null
      try res = inner(ctx, url, fetchdef)
      catch { case e: RuntimeException => err = e }

      if (!retryable(res, err) || attempt >= max) {
        if (err != null) throw err
        return res
      }

      val wait = backoff(res, attempt, minDelay, maxDelay, factor)
      track(attempt + 1, res, err, wait)
      sleep(wait)
      attempt += 1
    }
    null
  }

  private def retryable(res: Object, err: RuntimeException): Boolean = {
    if (err != null) return true
    if (res == null) return true
    val status = FeatureOptions.fresStatus(res)
    if (status < 0) return false
    var statuses = FeatureOptions.foptList(this.options, "statuses")
    if (statuses == null) statuses = java.util.List.of(
      java.lang.Integer.valueOf(408), java.lang.Integer.valueOf(425), java.lang.Integer.valueOf(429),
      java.lang.Integer.valueOf(500), java.lang.Integer.valueOf(502), java.lang.Integer.valueOf(503),
      java.lang.Integer.valueOf(504))
    val it = statuses.iterator()
    while (it.hasNext) {
      it.next() match { case n: java.lang.Number if n.intValue() == status => return true; case _ => }
    }
    false
  }

  private def backoff(res: Object, attempt: Int, minDelay: Int, maxDelay: Int, factor: Double): Int = {
    val ra = retryAfter(res)
    if (ra >= 0) return Math.min(ra, maxDelay)
    val base = minDelay * Math.pow(factor, attempt.toDouble)
    var jitter = 0
    if (FeatureOptions.foptBool(this.options, "jitter", true) && minDelay > 0) {
      jitter = ThreadLocalRandom.current().nextInt(minDelay)
    }
    val wait = base.toInt + jitter
    Math.min(wait, maxDelay)
  }

  private def retryAfter(res: Object): Int = {
    val v = FeatureOptions.fresHeader(res, "retry-after")
    if ("" == v) return -1
    val seconds = FeatureOptions.fparseInt(v, -1)
    if (seconds < 0) return -1
    seconds * 1000
  }

  private def sleep(ms: Int): Unit = {
    if (ms <= 0) return
    FeatureOptions.foptSleep(this.options).accept(ms)
  }

  private def track(attempt: Int, res: Object, err: RuntimeException, wait: Int): Unit = {
    this.attempts += 1
    val entry = new LinkedHashMap[String, Object]()
    entry.put("attempt", java.lang.Integer.valueOf(attempt))
    entry.put("wait", java.lang.Integer.valueOf(wait))
    val status = FeatureOptions.fresStatus(res)
    if (status >= 0) entry.put("status", java.lang.Integer.valueOf(status))
    if (err != null) entry.put("error", err.getMessage)
    this.retries.add(entry)
  }
}
