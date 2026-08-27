// Distributed-tracing telemetry. Opens a span per operation (prePoint),
// propagates trace context to the server as W3C `traceparent` plus
// `X-Trace-Id` / `X-Span-Id` headers (preRequest), and closes the span on
// completion (preDone) or failure (preUnexpected). Each span closes exactly
// once (the per-context marker in ctx.out is consumed on close). Finished
// spans accumulate on the feature; an `exporter` callback, when provided,
// is invoked with each finished span. Trace/span id generation (`idgen`)
// and the clock (`now`) are injectable for deterministic tests.

import Foundation

public final class TelemetryFeature: BaseFeature {
  private var client: UnivecSDK?
  private var options: VMap?
  private var seq = 0

  // Activity tracking (mirrors the ts client._telemetry record).
  public var spans: [VMap] = []
  public var activeSpans = 0

  private static let spanKey = "telemetry_span"

  public override init() {
    super.init()
    version = "0.0.1"
    name = "telemetry"
    active = true
  }

  public override func initFeature(_ ctx: Context, _ options: VMap) {
    client = ctx.client
    self.options = options
    active = foptBool(options, "active", false)
    seq = 0
  }

  public override func prePoint(_ ctx: Context) {
    if !active {
      return
    }

    let entity = ctx.op?.entity ?? "_"
    let opname = ctx.op?.name ?? "_"

    let span = VMap()
    span.entries["traceId"] = .string(id("trace"))
    span.entries["spanId"] = .string(id("span"))
    span.entries["name"] = .string(entity + "." + opname)
    span.entries["start"] = .int(foptNow(options)())
    ctx.out[TelemetryFeature.spanKey] = span
    activeSpans += 1
  }

  public override func preRequest(_ ctx: Context) {
    if !active {
      return
    }

    let span = ctx.out[TelemetryFeature.spanKey] as? VMap
    guard let span = span, let spec = ctx.spec else {
      return
    }

    let h = foptMap(options, "headers")
    let traceId = gp(span, "traceId").asString ?? ""
    let spanId = gp(span, "spanId").asString ?? ""
    spec.headers.entries[foptStr(h, "trace", "X-Trace-Id")] = .string(traceId)
    spec.headers.entries[foptStr(h, "span", "X-Span-Id")] = .string(spanId)
    spec.headers.entries[foptStr(h, "parent", "traceparent")] =
      .string("00-" + traceId + "-" + spanId + "-01")
  }

  public override func preDone(_ ctx: Context) {
    close(ctx, ctx.result != nil && ctx.result!.ok && ctx.result!.err == nil)
  }

  public override func preUnexpected(_ ctx: Context) {
    close(ctx, false)
  }

  private func close(_ ctx: Context, _ ok: Bool) {
    // Close once per operation; a preDone followed by a pipeline failure
    // (non-2xx) fires preUnexpected too, which then finds no open span.
    guard let span = ctx.out[TelemetryFeature.spanKey] as? VMap else {
      return
    }
    ctx.out.removeValue(forKey: TelemetryFeature.spanKey)

    let end = foptNow(options)()
    let start = toLong(gp(span, "start"))
    var dur = end - start
    if dur < 0 {
      dur = 0
    }
    span.entries["end"] = .int(end)
    span.entries["durationMs"] = .int(dur)
    span.entries["ok"] = .bool(ok)

    activeSpans -= 1
    spans.append(span)

    if let exporter = gp(options, "exporter").asNative as? (VMap) -> Void {
      exporter(span)
    }
  }

  private func id(_ kind: String) -> String {
    if let idgen = gp(options, "idgen").asNative as? (String) -> String {
      return idgen(kind)
    }
    // Deterministic-ish sequential id; unique within a client instance.
    seq += 1
    var n = String(seq, radix: 16)
    while n.count < 4 { n = "0" + n }
    let prefix = kind == "trace" ? "t" : "s"
    while n.count < 16 { n += "0" }
    return prefix + n
  }
}
