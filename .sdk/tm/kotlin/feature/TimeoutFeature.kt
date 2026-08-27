package KOTLINPACKAGE.feature

import java.util.concurrent.CompletableFuture
import java.util.concurrent.CompletionException
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.FetcherFn
import KOTLINPACKAGE.core.SdkClient

// Per-request timeout. Wraps the active transport and races each attempt
// against a deadline; if the deadline wins, the request resolves to a
// `timeout` error instead of hanging.
class TimeoutFeature : BaseFeature("timeout", "0.0.1", true) {

  private var client: SdkClient? = null
  private var options: MutableMap<String, Any?>? = null

  // Activity tracking (mirrors the ts client._timeout record).
  var count = 0
  var ms = 0

  override fun init(ctx: Context, options: MutableMap<String, Any?>) {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)

    if (!this.active) {
      return
    }

    val inner: FetcherFn = ctx.utility!!.fetcher

    ctx.utility!!.fetcher = { ctx2, url, fetchdef -> withTimeout(ctx2, url, fetchdef, inner) }
  }

  private fun withTimeout(ctx: Context, url: String, fetchdef: MutableMap<String, Any?>, inner: FetcherFn): Any? {
    val deadline = FeatureOptions.foptInt(this.options, "ms", 30000)
    if (deadline <= 0) {
      return inner(ctx, url, fetchdef)
    }

    val fut: CompletableFuture<Any?> = CompletableFuture.supplyAsync { inner(ctx, url, fetchdef) }

    try {
      return fut.get(deadline.toLong(), TimeUnit.MILLISECONDS)
    } catch (e: TimeoutException) {
      track(deadline)
      throw ctx.makeError("timeout", "Request exceeded timeout of ${deadline}ms")
    } catch (e: ExecutionException) {
      var cause: Throwable? = e.cause
      if (cause is CompletionException && cause.cause != null) {
        cause = cause.cause
      }
      if (cause is RuntimeException) {
        throw cause
      }
      if (cause is Error) {
        throw cause
      }
      throw RuntimeException(cause)
    } catch (e: InterruptedException) {
      Thread.currentThread().interrupt()
      throw RuntimeException(e)
    }
  }

  private fun track(deadline: Int) {
    this.count++
    this.ms = deadline
  }
}
