package SCALAPACKAGE.feature

import java.util.{LinkedHashMap, Map => JMap}
import SCALAPACKAGE.core.{Context, SdkClient}

// Public per-bucket aggregate (mirrors the java static nested MetricsBucket).
// Tests read `f.total.count`, `bucket.totalMs`, etc.
class MetricsBucket {
  var count: Int = 0
  var ok: Int = 0
  var err: Int = 0
  var totalMs: Long = 0
  var maxMs: Long = 0
}

// Statistics capture. Records per-operation counters and latency for every
// call: totals plus a breakdown keyed by `<entity>.<op>`. Timing starts at
// endpoint resolution (PrePoint) and stops when the call returns (PreDone)
// or fails (PreUnexpected); each operation is recorded exactly once (the
// per-context start marker in ctx.out is consumed on record). The clock is
// injectable (`now`) for deterministic tests.
class MetricsFeature extends BaseFeature("metrics", "0.0.1", true) {

  private var client: SdkClient = null
  private var options: JMap[String, Object] = null

  // Aggregates (mirrors the ts client._metrics record).
  var total: MetricsBucket = new MetricsBucket()
  var ops: JMap[String, MetricsBucket] = new LinkedHashMap[String, MetricsBucket]()

  private val METRICS_START_KEY = "metrics_start"

  override def init(ctx: Context, options: JMap[String, Object]): Unit = {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)

    this.total = new MetricsBucket()
    this.ops = new LinkedHashMap[String, MetricsBucket]()
  }

  override def prePoint(ctx: Context): Unit = {
    if (!this.active) {
      return
    }
    ctx.out.put(METRICS_START_KEY, java.lang.Long.valueOf(FeatureOptions.foptNow(this.options).getAsLong()))
  }

  override def preDone(ctx: Context): Unit = {
    // Classify by the actual result: a 4xx/5xx that flows through still
    // reaches PreDone before the pipeline errors.
    record(ctx, ctx.result != null && ctx.result.ok && ctx.result.err == null)
  }

  override def preUnexpected(ctx: Context): Unit = {
    record(ctx, false)
  }

  private def record(ctx: Context, ok: Boolean): Unit = {
    // Record once per operation: the missing start marker makes a second
    // call (PreDone followed by PreUnexpected on failure) a no-op.
    val startRaw = ctx.out.get(METRICS_START_KEY)
    startRaw match {
      case _: java.lang.Long =>
      case _ => return
    }
    ctx.out.remove(METRICS_START_KEY)
    val start = startRaw.asInstanceOf[java.lang.Long].longValue()

    var dur = FeatureOptions.foptNow(this.options).getAsLong() - start
    if (dur < 0) {
      dur = 0
    }

    var entity = "_"
    var opname = "_"
    if (ctx.op != null) {
      entity = ctx.op.entity
      opname = ctx.op.name
    }
    val key = entity + "." + opname

    var op = this.ops.get(key)
    if (op == null) {
      op = new MetricsBucket()
      this.ops.put(key, op)
    }

    bump(this.total, ok, dur)
    bump(op, ok, dur)
  }

  private def bump(bucket: MetricsBucket, ok: Boolean, dur: Long): Unit = {
    bucket.count += 1
    if (ok) {
      bucket.ok += 1
    } else {
      bucket.err += 1
    }
    bucket.totalMs += dur
    if (dur > bucket.maxMs) {
      bucket.maxMs = dur
    }
  }
}
