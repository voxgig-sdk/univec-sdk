// Distributed-tracing telemetry. Opens a span per operation (PrePoint),
// propagates trace context to the server as W3C `traceparent` plus
// `X-Trace-Id` / `X-Span-Id` headers (PreRequest), and closes the span on
// completion (PreDone) or failure (PreUnexpected). Each span closes exactly
// once (the per-context marker in ctx.Out is consumed on close). Finished
// spans accumulate on the feature; an `exporter` callback, when provided,
// is invoked with each finished span. Trace/span id generation (`idgen`)
// and the clock (`now`) are injectable for deterministic tests.

using static UnivecSdk.Feature.FeatureOptions;

namespace UnivecSdk.Feature;

public class TelemetryFeature : BaseFeature
{
    private UnivecSDK? _client;
    private Dictionary<string, object?>? _options;
    private int _seq;

    // Activity tracking (mirrors the ts client._telemetry record).
    public List<Dictionary<string, object?>> Spans = new();
    public int ActiveSpans;

    private const string SpanKey = "telemetry_span";

    public TelemetryFeature()
    {
        Version = "0.0.1";
        Name = "telemetry";
        Active = true;
    }

    public override void Init(Context ctx, Dictionary<string, object?> options)
    {
        _client = ctx.Client;
        _options = options;
        Active = FoptBool(options, "active", false);
        _seq = 0;
    }

    public override void PrePoint(Context ctx)
    {
        if (!Active)
        {
            return;
        }

        var entity = ctx.Op?.Entity ?? "_";
        var opname = ctx.Op?.Name ?? "_";

        var span = new Dictionary<string, object?>
        {
            ["traceId"] = Id("trace"),
            ["spanId"] = Id("span"),
            ["name"] = entity + "." + opname,
            ["start"] = FoptNow(_options)(),
        };
        ctx.Out[SpanKey] = span;
        ActiveSpans++;
    }

    public override void PreRequest(Context ctx)
    {
        if (!Active)
        {
            return;
        }

        var span = ctx.Out.TryGetValue(SpanKey, out var raw)
            ? raw as Dictionary<string, object?> : null;
        var spec = ctx.Spec;
        if (span == null || spec == null)
        {
            return;
        }
        spec.Headers ??= new Dictionary<string, object?>();

        var h = FoptMap(_options, "headers");
        var traceId = span["traceId"] as string ?? "";
        var spanId = span["spanId"] as string ?? "";
        spec.Headers[FoptStr(h, "trace", "X-Trace-Id")] = traceId;
        spec.Headers[FoptStr(h, "span", "X-Span-Id")] = spanId;
        spec.Headers[FoptStr(h, "parent", "traceparent")] =
            "00-" + traceId + "-" + spanId + "-01";
    }

    public override void PreDone(Context ctx)
    {
        Close(ctx, ctx.Result != null && ctx.Result.Ok && ctx.Result.Err == null);
    }

    public override void PreUnexpected(Context ctx)
    {
        Close(ctx, false);
    }

    private void Close(Context ctx, bool ok)
    {
        // Close once per operation; a PreDone followed by a pipeline failure
        // (non-2xx) fires PreUnexpected too, which then finds no open span.
        var span = ctx.Out.TryGetValue(SpanKey, out var raw)
            ? raw as Dictionary<string, object?> : null;
        if (span == null)
        {
            return;
        }
        ctx.Out.Remove(SpanKey);

        var end = FoptNow(_options)();
        var start = span["start"] is long ls ? ls : Helpers.ToLong(span["start"]);
        var dur = end - start;
        if (dur < 0)
        {
            dur = 0;
        }
        span["end"] = end;
        span["durationMs"] = dur;
        span["ok"] = ok;

        ActiveSpans--;
        Spans.Add(span);

        if (Opt(_options, "exporter") is Action<Dictionary<string, object?>> exporter)
        {
            exporter(span);
        }
    }

    private string Id(string kind)
    {
        if (Opt(_options, "idgen") is Func<string, string> idgen)
        {
            return idgen(kind);
        }
        // Deterministic-ish sequential id; unique within a client instance.
        _seq++;
        var n = _seq.ToString("x4");
        var prefix = kind == "trace" ? "t" : "s";
        while (n.Length < 16)
        {
            n += "0";
        }
        return prefix + n;
    }
}
