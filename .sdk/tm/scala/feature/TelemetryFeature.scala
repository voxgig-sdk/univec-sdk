package SCALAPACKAGE.feature

import java.util.{ArrayList, LinkedHashMap, List => JList, Map => JMap}
import SCALAPACKAGE.core.{Context, Helpers, SdkClient}

// Distributed-tracing telemetry. Opens a span per operation (PrePoint),
// propagates trace context to the server as W3C `traceparent` plus
// `X-Trace-Id` / `X-Span-Id` headers (PreRequest), and closes the span on
// completion (PreDone) or failure (PreUnexpected). Each span closes exactly
// once (the per-context marker in ctx.out is consumed on close). Finished
// spans accumulate on the feature; an `exporter` callback, when provided,
// is invoked with each finished span. Trace/span id generation (`idgen`)
// and the clock (`now`) are injectable for deterministic tests.
class TelemetryFeature extends BaseFeature("telemetry", "0.0.1", true) {

  private var client: SdkClient = null
  private var options: JMap[String, Object] = null
  private var seq: Int = 0

  // Activity tracking (mirrors the ts client._telemetry record).
  var spans: JList[JMap[String, Object]] = new ArrayList[JMap[String, Object]]()
  var activeSpans: Int = 0

  private val TELEMETRY_SPAN_KEY = "telemetry_span"

  override def init(ctx: Context, options: JMap[String, Object]): Unit = {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)
    this.seq = 0
  }

  override def prePoint(ctx: Context): Unit = {
    if (!this.active) {
      return
    }

    var entity = "_"
    var opname = "_"
    if (ctx.op != null) {
      entity = ctx.op.entity
      opname = ctx.op.name
    }

    val span = new LinkedHashMap[String, Object]()
    span.put("traceId", id("trace"))
    span.put("spanId", id("span"))
    span.put("name", entity + "." + opname)
    span.put("start", java.lang.Long.valueOf(FeatureOptions.foptNow(this.options).getAsLong()))
    ctx.out.put(TELEMETRY_SPAN_KEY, span)
    this.activeSpans += 1
  }

  override def preRequest(ctx: Context): Unit = {
    if (!this.active) {
      return
    }

    val span = Helpers.toMapAny(ctx.out.get(TELEMETRY_SPAN_KEY))
    val spec = ctx.spec
    if (span == null || spec == null) {
      return
    }
    if (spec.headers == null) {
      spec.headers = new LinkedHashMap[String, Object]()
    }

    val h = FeatureOptions.foptMap(this.options, "headers")
    val traceId = span.get("traceId") match { case s: String => s; case _ => "" }
    val spanId = span.get("spanId") match { case s: String => s; case _ => "" }
    spec.headers.put(FeatureOptions.foptStr(h, "trace", "X-Trace-Id"), traceId)
    spec.headers.put(FeatureOptions.foptStr(h, "span", "X-Span-Id"), spanId)
    spec.headers.put(FeatureOptions.foptStr(h, "parent", "traceparent"),
      "00-" + traceId + "-" + spanId + "-01")
  }

  override def preDone(ctx: Context): Unit = {
    close(ctx, ctx.result != null && ctx.result.ok && ctx.result.err == null)
  }

  override def preUnexpected(ctx: Context): Unit = {
    close(ctx, false)
  }

  private def close(ctx: Context, ok: Boolean): Unit = {
    // Close once per operation; a PreDone followed by a pipeline failure
    // (non-2xx) fires PreUnexpected too, which then finds no open span.
    val span = Helpers.toMapAny(ctx.out.get(TELEMETRY_SPAN_KEY))
    if (span == null) {
      return
    }
    ctx.out.remove(TELEMETRY_SPAN_KEY)

    val end = FeatureOptions.foptNow(this.options).getAsLong()
    val start = Helpers.toLong(span.get("start"), 0)
    var dur = end - start
    if (dur < 0) {
      dur = 0
    }
    span.put("end", java.lang.Long.valueOf(end))
    span.put("durationMs", java.lang.Long.valueOf(dur))
    span.put("ok", java.lang.Boolean.valueOf(ok))

    this.activeSpans -= 1
    this.spans.add(span)

    this.options.get("exporter") match {
      case c: java.util.function.Consumer[_] =>
        c.asInstanceOf[java.util.function.Consumer[JMap[String, Object]]].accept(span)
      case _ =>
    }
  }

  private def id(kind: String): String = {
    this.options.get("idgen") match {
      case f: java.util.function.Function[_, _] =>
        return f.asInstanceOf[java.util.function.Function[String, String]].apply(kind)
      case _ =>
    }
    // Deterministic-ish sequential id; unique within a client instance.
    this.seq += 1
    val n = new StringBuilder(String.format("%04x", java.lang.Integer.valueOf(this.seq)))
    val prefix = if ("trace".equals(kind)) "t" else "s"
    while (n.length < 16) {
      n.append("0")
    }
    prefix + n.toString
  }
}
