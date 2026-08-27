package KOTLINPACKAGE.feature

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.SdkClient

// Statistics capture. Records per-operation counters and latency for every
// call: totals plus a breakdown keyed by `<entity>.<op>`. The clock is
// injectable (`now`) for deterministic tests.
class MetricsFeature : BaseFeature("metrics", "0.0.1", true) {

  private var client: SdkClient? = null
  private var options: MutableMap<String, Any?>? = null

  // Aggregates (mirrors the ts client._metrics record).
  var total = MetricsBucket()
  var ops: MutableMap<String, MetricsBucket> = linkedMapOf()

  class MetricsBucket {
    var count = 0
    var ok = 0
    var err = 0
    var totalMs = 0L
    var maxMs = 0L
  }

  override fun init(ctx: Context, options: MutableMap<String, Any?>) {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)

    this.total = MetricsBucket()
    this.ops = linkedMapOf()
  }

  override fun prePoint(ctx: Context) {
    if (!this.active) {
      return
    }
    ctx.out[METRICS_START_KEY] = FeatureOptions.foptNow(this.options).getAsLong()
  }

  override fun preDone(ctx: Context) {
    val result = ctx.result
    record(ctx, result != null && result.ok && result.err == null)
  }

  override fun preUnexpected(ctx: Context) {
    record(ctx, false)
  }

  private fun record(ctx: Context, ok: Boolean) {
    // Record once per operation: the missing start marker makes a second
    // call (PreDone followed by PreUnexpected on failure) a no-op.
    val startRaw = ctx.out[METRICS_START_KEY]
    if (startRaw !is Long) {
      return
    }
    ctx.out.remove(METRICS_START_KEY)
    val start = startRaw

    var dur = FeatureOptions.foptNow(this.options).getAsLong() - start
    if (dur < 0) {
      dur = 0
    }

    val entity = ctx.op.entity
    val opname = ctx.op.name
    val key = "$entity.$opname"

    var op = this.ops[key]
    if (op == null) {
      op = MetricsBucket()
      this.ops[key] = op
    }

    bump(this.total, ok, dur)
    bump(op, ok, dur)
  }

  private fun bump(bucket: MetricsBucket, ok: Boolean, dur: Long) {
    bucket.count++
    if (ok) {
      bucket.ok++
    } else {
      bucket.err++
    }
    bucket.totalMs += dur
    if (dur > bucket.maxMs) {
      bucket.maxMs = dur
    }
  }

  companion object {
    private const val METRICS_START_KEY = "metrics_start"
  }
}
