package KOTLINPACKAGE.feature

import java.util.concurrent.ThreadLocalRandom

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.FetcherFn
import KOTLINPACKAGE.core.SdkClient

// Automatic retry of transient failures with exponential backoff and jitter.
// Wraps the active transport so a single operation call may make several HTTP
// attempts. A failure is retryable when the transport throws, returns
// nothing, or responds with a status in `statuses`
// (default: 408, 425, 429, 500, 502, 503, 504).
class RetryFeature : BaseFeature("retry", "0.0.1", true) {

  private var client: SdkClient? = null
  private var options: MutableMap<String, Any?>? = null

  // Activity tracking (mirrors the ts client._retry record).
  var attempts = 0
  var retries: MutableList<MutableMap<String, Any?>> = mutableListOf()

  override fun init(ctx: Context, options: MutableMap<String, Any?>) {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)

    if (!this.active) {
      return
    }

    val inner: FetcherFn = ctx.utility!!.fetcher

    ctx.utility!!.fetcher = { ctx2, url, fetchdef -> withRetry(ctx2, url, fetchdef, inner) }
  }

  private fun withRetry(ctx: Context, url: String, fetchdef: MutableMap<String, Any?>, inner: FetcherFn): Any? {
    val max = FeatureOptions.foptInt(this.options, "retries", 2)
    val minDelay = FeatureOptions.foptInt(this.options, "minDelay", 50)
    val maxDelay = FeatureOptions.foptInt(this.options, "maxDelay", 2000)
    val factor = FeatureOptions.foptNum(this.options, "factor", 2.0)

    var attempt = 0

    while (true) {
      var res: Any? = null
      var err: RuntimeException? = null
      try {
        res = inner(ctx, url, fetchdef)
      } catch (e: RuntimeException) {
        err = e
      }

      if (!retryable(res, err) || attempt >= max) {
        if (err != null) {
          throw err
        }
        return res
      }

      val wait = backoff(res, attempt, minDelay, maxDelay, factor)
      track(attempt + 1, res, err, wait)
      sleep(wait)
      attempt++
    }
  }

  private fun retryable(res: Any?, err: RuntimeException?): Boolean {
    if (err != null) {
      return true
    }
    if (res == null) {
      return true
    }
    val status = FeatureOptions.fresStatus(res)
    if (status < 0) {
      return false
    }
    var statuses: List<Any?>? = FeatureOptions.foptList(this.options, "statuses")
    if (statuses == null) {
      statuses = listOf(408, 425, 429, 500, 502, 503, 504)
    }
    for (s in statuses) {
      if (s is Number && s.toInt() == status) {
        return true
      }
    }
    return false
  }

  private fun backoff(res: Any?, attempt: Int, minDelay: Int, maxDelay: Int, factor: Double): Int {
    // Honour a server-provided Retry-After (seconds) when present.
    val ra = retryAfter(res)
    if (ra >= 0) {
      return minOf(ra, maxDelay)
    }
    val base = minDelay * Math.pow(factor, attempt.toDouble())
    var jitter = 0
    if (FeatureOptions.foptBool(this.options, "jitter", true) && minDelay > 0) {
      jitter = ThreadLocalRandom.current().nextInt(minDelay)
    }
    val wait = base.toInt() + jitter
    return minOf(wait, maxDelay)
  }

  private fun retryAfter(res: Any?): Int {
    val v = FeatureOptions.fresHeader(res, "retry-after")
    if ("" == v) {
      return -1
    }
    val seconds = FeatureOptions.fparseInt(v, -1)
    if (seconds < 0) {
      return -1
    }
    return seconds * 1000
  }

  private fun sleep(ms: Int) {
    if (ms <= 0) {
      return
    }
    FeatureOptions.foptSleep(this.options).accept(ms)
  }

  private fun track(attempt: Int, res: Any?, err: RuntimeException?, wait: Int) {
    this.attempts++

    val entry = linkedMapOf<String, Any?>()
    entry["attempt"] = attempt
    entry["wait"] = wait
    val status = FeatureOptions.fresStatus(res)
    if (status >= 0) {
      entry["status"] = status
    }
    if (err != null) {
      entry["error"] = err.message
    }
    this.retries.add(entry)
  }
}
