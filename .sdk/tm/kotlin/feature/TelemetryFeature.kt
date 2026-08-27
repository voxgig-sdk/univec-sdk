package KOTLINPACKAGE.feature

import java.util.function.Consumer
import java.util.function.Function

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.Helpers
import KOTLINPACKAGE.core.SdkClient

// Distributed-tracing telemetry. Opens a span per operation (PrePoint),
// propagates trace context to the server (PreRequest), and closes the span on
// completion (PreDone) or failure (PreUnexpected). Trace/span id generation
// (`idgen`) and the clock (`now`) are injectable.
@Suppress("UNCHECKED_CAST")
class TelemetryFeature : BaseFeature("telemetry", "0.0.1", true) {

  private var client: SdkClient? = null
  private var options: MutableMap<String, Any?>? = null
  private var seq = 0

  // Activity tracking (mirrors the ts client._telemetry record).
  var spans: MutableList<MutableMap<String, Any?>> = mutableListOf()
  var activeSpans = 0

  override fun init(ctx: Context, options: MutableMap<String, Any?>) {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)
    this.seq = 0
  }

  override fun prePoint(ctx: Context) {
    if (!this.active) {
      return
    }

    val entity = ctx.op.entity
    val opname = ctx.op.name

    val span = linkedMapOf<String, Any?>()
    span["traceId"] = id("trace")
    span["spanId"] = id("span")
    span["name"] = "$entity.$opname"
    span["start"] = FeatureOptions.foptNow(this.options).getAsLong()
    ctx.out[TELEMETRY_SPAN_KEY] = span
    this.activeSpans++
  }

  override fun preRequest(ctx: Context) {
    if (!this.active) {
      return
    }

    val span = Helpers.toMapAny(ctx.out[TELEMETRY_SPAN_KEY])
    val spec = ctx.spec
    if (span == null || spec == null) {
      return
    }

    val h = FeatureOptions.foptMap(this.options, "headers")
    val traceId = if (span["traceId"] is String) span["traceId"] as String else ""
    val spanId = if (span["spanId"] is String) span["spanId"] as String else ""
    spec.headers[FeatureOptions.foptStr(h, "trace", "X-Trace-Id")] = traceId
    spec.headers[FeatureOptions.foptStr(h, "span", "X-Span-Id")] = spanId
    spec.headers[FeatureOptions.foptStr(h, "parent", "traceparent")] = "00-$traceId-$spanId-01"
  }

  override fun preDone(ctx: Context) {
    val result = ctx.result
    close(ctx, result != null && result.ok && result.err == null)
  }

  override fun preUnexpected(ctx: Context) {
    close(ctx, false)
  }

  private fun close(ctx: Context, ok: Boolean) {
    val span = Helpers.toMapAny(ctx.out[TELEMETRY_SPAN_KEY]) ?: return
    ctx.out.remove(TELEMETRY_SPAN_KEY)

    val end = FeatureOptions.foptNow(this.options).getAsLong()
    val start = Helpers.toLong(span["start"], 0)
    var dur = end - start
    if (dur < 0) {
      dur = 0
    }
    span["end"] = end
    span["durationMs"] = dur
    span["ok"] = ok

    this.activeSpans--
    this.spans.add(span)

    val exporter = this.options?.get("exporter")
    if (exporter is Consumer<*>) {
      (exporter as Consumer<MutableMap<String, Any?>>).accept(span)
    }
  }

  private fun id(kind: String): String {
    val ig = this.options?.get("idgen")
    if (ig is Function<*, *>) {
      return (ig as Function<String, String>).apply(kind)
    }
    // Deterministic-ish sequential id; unique within a client instance.
    this.seq++
    val n = StringBuilder(String.format("%04x", this.seq))
    val prefix = if ("trace" == kind) "t" else "s"
    while (n.length < 16) {
      n.append("0")
    }
    return prefix + n
  }

  companion object {
    private const val TELEMETRY_SPAN_KEY = "telemetry_span"
  }
}
