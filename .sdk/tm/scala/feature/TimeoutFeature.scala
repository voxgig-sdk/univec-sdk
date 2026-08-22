package SCALAPACKAGE.feature

import java.util.{Map => JMap}
import java.util.concurrent.{CompletableFuture, CompletionException, TimeUnit, TimeoutException}
import java.util.function.Supplier
import SCALAPACKAGE.core.{Context, FetcherFn, SdkClient}

// Per-request timeout: races each attempt against a deadline.
class TimeoutFeature extends BaseFeature("timeout", "0.0.1", true) {

  private var client: SdkClient = null
  private var options: JMap[String, Object] = null

  var count: Int = 0
  var ms: Int = 0

  override def init(ctx: Context, options: JMap[String, Object]): Unit = {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)
    if (!this.active) return

    val inner: FetcherFn = ctx.utility.fetcher
    ctx.utility.fetcher = (ctx2, url, fetchdef) => withTimeout(ctx2, url, fetchdef, inner)
  }

  private def withTimeout(ctx: Context, url: String, fetchdef: JMap[String, Object], inner: FetcherFn): Object = {
    val deadline = FeatureOptions.foptInt(this.options, "ms", 30000)
    if (deadline <= 0) return inner(ctx, url, fetchdef)

    val sup: Supplier[Object] = () => inner(ctx, url, fetchdef)
    val fut = CompletableFuture.supplyAsync(sup)

    try fut.get(deadline.toLong, TimeUnit.MILLISECONDS)
    catch {
      case _: TimeoutException =>
        track(deadline)
        throw ctx.makeError("timeout", "Request exceeded timeout of " + deadline + "ms")
      case e: java.util.concurrent.ExecutionException =>
        var cause = e.getCause
        cause match { case ce: CompletionException if ce.getCause != null => cause = ce.getCause; case _ => }
        cause match {
          case re: RuntimeException => throw re
          case err: Error => throw err
          case _ => throw new RuntimeException(cause)
        }
      case _: InterruptedException =>
        Thread.currentThread().interrupt()
        throw new RuntimeException("interrupted")
    }
  }

  private def track(deadline: Int): Unit = {
    this.count += 1
    this.ms = deadline
  }
}
