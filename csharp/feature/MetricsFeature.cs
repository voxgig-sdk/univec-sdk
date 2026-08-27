// Statistics capture. Records per-operation counters and latency for every
// call: totals plus a breakdown keyed by `<entity>.<op>`. Timing starts at
// endpoint resolution (PrePoint) and stops when the call returns (PreDone)
// or fails (PreUnexpected); each operation is recorded exactly once (the
// per-context start marker in ctx.Out is consumed on record). The clock is
// injectable (`now`) for deterministic tests.

using static UnivecSdk.Feature.FeatureOptions;

namespace UnivecSdk.Feature;

public class MetricsBucket
{
    public int Count;
    public int Ok;
    public int Err;
    public long TotalMs;
    public long MaxMs;
}

public class MetricsFeature : BaseFeature
{
    private UnivecSDK? _client;
    private Dictionary<string, object?>? _options;

    // Aggregates (mirrors the ts client._metrics record).
    public MetricsBucket Total = new();
    public Dictionary<string, MetricsBucket> Ops = new();

    private const string StartKey = "metrics_start";

    public MetricsFeature()
    {
        Version = "0.0.1";
        Name = "metrics";
        Active = true;
    }

    public override void Init(Context ctx, Dictionary<string, object?> options)
    {
        _client = ctx.Client;
        _options = options;
        Active = FoptBool(options, "active", false);

        Total = new MetricsBucket();
        Ops = new Dictionary<string, MetricsBucket>();
    }

    public override void PrePoint(Context ctx)
    {
        if (!Active)
        {
            return;
        }
        ctx.Out[StartKey] = FoptNow(_options)();
    }

    public override void PreDone(Context ctx)
    {
        // Classify by the actual result: a 4xx/5xx that flows through still
        // reaches PreDone before the pipeline errors.
        Record(ctx, ctx.Result != null && ctx.Result.Ok && ctx.Result.Err == null);
    }

    public override void PreUnexpected(Context ctx)
    {
        Record(ctx, false);
    }

    private void Record(Context ctx, bool ok)
    {
        // Record once per operation: the missing start marker makes a second
        // call (PreDone followed by PreUnexpected on failure) a no-op.
        if (!ctx.Out.TryGetValue(StartKey, out var raw) || raw is not long start)
        {
            return;
        }
        ctx.Out.Remove(StartKey);

        var dur = FoptNow(_options)() - start;
        if (dur < 0)
        {
            dur = 0;
        }

        var entity = ctx.Op?.Entity ?? "_";
        var opname = ctx.Op?.Name ?? "_";
        var key = entity + "." + opname;

        if (!Ops.TryGetValue(key, out var op))
        {
            op = new MetricsBucket();
            Ops[key] = op;
        }

        Bump(Total, ok, dur);
        Bump(op, ok, dur);
    }

    private static void Bump(MetricsBucket bucket, bool ok, long dur)
    {
        bucket.Count++;
        if (ok)
        {
            bucket.Ok++;
        }
        else
        {
            bucket.Err++;
        }
        bucket.TotalMs += dur;
        if (dur > bucket.MaxMs)
        {
            bucket.MaxMs = dur;
        }
    }
}
