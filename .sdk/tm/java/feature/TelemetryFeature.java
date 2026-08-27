package JAVAPACKAGE.feature;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Consumer;
import java.util.function.Function;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Helpers;
import JAVAPACKAGE.core.SdkClient;
import JAVAPACKAGE.core.Spec;

// Distributed-tracing telemetry. Opens a span per operation (PrePoint),
// propagates trace context to the server as W3C `traceparent` plus
// `X-Trace-Id` / `X-Span-Id` headers (PreRequest), and closes the span on
// completion (PreDone) or failure (PreUnexpected). Each span closes exactly
// once (the per-context marker in ctx.out is consumed on close). Finished
// spans accumulate on the feature; an `exporter` callback, when provided,
// is invoked with each finished span. Trace/span id generation (`idgen`)
// and the clock (`now`) are injectable for deterministic tests.
@SuppressWarnings({"unchecked"})
public class TelemetryFeature extends BaseFeature {

  private SdkClient client;
  private Map<String, Object> options;
  private int seq = 0;

  // Activity tracking (mirrors the ts client._telemetry record).
  public List<Map<String, Object>> spans = new ArrayList<>();
  public int activeSpans = 0;

  private static final String TELEMETRY_SPAN_KEY = "telemetry_span";

  public TelemetryFeature() {
    super("telemetry", "0.0.1", true);
  }

  @Override
  public void init(Context ctx, Map<String, Object> options) {
    this.client = ctx.client;
    this.options = options;
    this.active = FeatureOptions.foptBool(options, "active", false);
    this.seq = 0;
  }

  @Override
  public void prePoint(Context ctx) {
    if (!this.active) {
      return;
    }

    String entity = "_";
    String opname = "_";
    if (ctx.op != null) {
      entity = ctx.op.entity;
      opname = ctx.op.name;
    }

    Map<String, Object> span = new LinkedHashMap<>();
    span.put("traceId", id("trace"));
    span.put("spanId", id("span"));
    span.put("name", entity + "." + opname);
    span.put("start", FeatureOptions.foptNow(this.options).getAsLong());
    ctx.out.put(TELEMETRY_SPAN_KEY, span);
    this.activeSpans++;
  }

  @Override
  public void preRequest(Context ctx) {
    if (!this.active) {
      return;
    }

    Map<String, Object> span = Helpers.toMapAny(ctx.out.get(TELEMETRY_SPAN_KEY));
    Spec spec = ctx.spec;
    if (span == null || spec == null) {
      return;
    }
    if (spec.headers == null) {
      spec.headers = new LinkedHashMap<>();
    }

    Map<String, Object> h = FeatureOptions.foptMap(this.options, "headers");
    String traceId = span.get("traceId") instanceof String
        ? (String) span.get("traceId") : "";
    String spanId = span.get("spanId") instanceof String
        ? (String) span.get("spanId") : "";
    spec.headers.put(FeatureOptions.foptStr(h, "trace", "X-Trace-Id"), traceId);
    spec.headers.put(FeatureOptions.foptStr(h, "span", "X-Span-Id"), spanId);
    spec.headers.put(FeatureOptions.foptStr(h, "parent", "traceparent"),
        "00-" + traceId + "-" + spanId + "-01");
  }

  @Override
  public void preDone(Context ctx) {
    close(ctx, ctx.result != null && ctx.result.ok && ctx.result.err == null);
  }

  @Override
  public void preUnexpected(Context ctx) {
    close(ctx, false);
  }

  private void close(Context ctx, boolean ok) {
    // Close once per operation; a PreDone followed by a pipeline failure
    // (non-2xx) fires PreUnexpected too, which then finds no open span.
    Map<String, Object> span = Helpers.toMapAny(ctx.out.get(TELEMETRY_SPAN_KEY));
    if (span == null) {
      return;
    }
    ctx.out.remove(TELEMETRY_SPAN_KEY);

    long end = FeatureOptions.foptNow(this.options).getAsLong();
    long start = Helpers.toLong(span.get("start"), 0);
    long dur = end - start;
    if (dur < 0) {
      dur = 0;
    }
    span.put("end", end);
    span.put("durationMs", dur);
    span.put("ok", ok);

    this.activeSpans--;
    this.spans.add(span);

    if (this.options.get("exporter") instanceof Consumer) {
      ((Consumer<Map<String, Object>>) this.options.get("exporter")).accept(span);
    }
  }

  private String id(String kind) {
    if (this.options.get("idgen") instanceof Function) {
      return ((Function<String, String>) this.options.get("idgen")).apply(kind);
    }
    // Deterministic-ish sequential id; unique within a client instance.
    this.seq++;
    StringBuilder n = new StringBuilder(String.format("%04x", this.seq));
    String prefix = "trace".equals(kind) ? "t" : "s";
    while (n.length() < 16) {
      n.append("0");
    }
    return prefix + n;
  }
}
