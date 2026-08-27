// Audit trail. Emits a structured record for every operation - who (actor),
// what (entity + op), the outcome, and a correlation id - suitable for
// compliance logging. Records accumulate on the feature (bounded by `max`,
// default 1000) and, when a `sink` callback is supplied, are also pushed to
// it (e.g. to forward to a SIEM). The actor is the per-call ctrl actor,
// falling back to the options `actor`, then "anonymous". Each operation is
// audited exactly once (the per-context marker in ctx.Out prevents a
// PreDone + PreUnexpected double-log). Timestamps use the injectable `now`
// clock so tests stay deterministic.

using static UnivecSdk.Feature.FeatureOptions;

namespace UnivecSdk.Feature;

public class AuditFeature : BaseFeature
{
    private UnivecSDK? _client;
    private Dictionary<string, object?>? _options;
    private int _seq;

    // Activity tracking (mirrors the ts client._audit record).
    public List<Dictionary<string, object?>> Records = new();

    private const string SeenKey = "audit_seen";

    public AuditFeature()
    {
        Version = "0.0.1";
        Name = "audit";
        Active = true;
    }

    public override void Init(Context ctx, Dictionary<string, object?> options)
    {
        _client = ctx.Client;
        _options = options;
        Active = FoptBool(options, "active", false);
        _seq = 0;
    }

    public override void PreDone(Context ctx)
    {
        // Outcome reflects the actual result; a non-2xx reaches PreDone
        // before the pipeline errors.
        var outcome = "error";
        if (ctx.Result != null && ctx.Result.Ok && ctx.Result.Err == null)
        {
            outcome = "ok";
        }
        Emit(ctx, outcome);
    }

    public override void PreUnexpected(Context ctx)
    {
        Emit(ctx, "error");
    }

    private void Emit(Context ctx, string outcome)
    {
        if (!Active)
        {
            return;
        }

        // One record per operation (PreDone + a following PreUnexpected on a
        // failure must not double-log).
        if (ctx.Out.TryGetValue(SeenKey, out var seen) && Equals(seen, true))
        {
            return;
        }
        ctx.Out[SeenKey] = true;

        _seq++;

        var actor = "anonymous";
        var optActor = FoptStr(_options, "actor", "");
        if (optActor != "")
        {
            actor = optActor;
        }
        if (ctx.Ctrl != null && ctx.Ctrl.Actor != "")
        {
            actor = ctx.Ctrl.Actor;
        }

        var entity = ctx.Op?.Entity ?? "_";
        var opname = ctx.Op?.Name ?? "_";

        var record = new Dictionary<string, object?>
        {
            ["seq"] = _seq,
            ["ts"] = FoptNow(_options)(),
            ["actor"] = actor,
            ["entity"] = entity,
            ["op"] = opname,
            ["outcome"] = outcome,
            ["correlationId"] = ctx.Id,
        };
        if (ctx.Result != null)
        {
            record["status"] = ctx.Result.Status;
        }

        Records.Add(record);
        var max = FoptInt(_options, "max", 1000);
        while (Records.Count > max)
        {
            Records.RemoveAt(0);
        }

        if (Opt(_options, "sink") is Action<Dictionary<string, object?>> sink)
        {
            sink(record);
        }
    }
}
