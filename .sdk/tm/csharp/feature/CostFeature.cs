// Cost tracking and spend budget. Uses BOTH seams, which is the point of
// the feature: money is spent per HTTP ATTEMPT (a retried call is charged
// again, because the upstream API charges it again), but it is owed by an
// OPERATION. So the transport wrap prices each attempt, and PreDone
// attributes the running total to `<entity>.<op>` and to the caller
// (`ctrl.actor`, the same actor the audit feature records).
//
// The price of an attempt comes from the first source that answers: a
// response header (`header` x `perUnit`), the rate table (`rates`, keyed
// '<entity>.<op>' / '<op>' / '*'), then the flat `unit`. A body figure
// (`path` x `perUnit`, e.g. "usage.total_tokens") is read at PreDone
// instead, from the already-parsed result. A body figure describes the
// whole call, so it REPLACES the per-attempt estimate rather than adding
// to it.
//
// `budget` caps total spend. With `onBudget` = "deny" a further operation
// is refused at PrePoint, before an endpoint is resolved and before
// anything reaches the network.
//
// ORDER MATTERS. Cost must sit INSIDE the cache, or a response served from
// cache is charged for money that was never spent.

using Voxgig.Struct;

using static UnivecSdk.Feature.FeatureOptions;

namespace UnivecSdk.Feature;

public class CostBucket
{
    public int Calls;
    public double Amount;
}

public class CostRecord
{
    public int Seq;
    public string Entity = "";
    public string Op = "";
    public string Actor = "";
    public double Amount;
    public string Currency = "";
    public string Source = "";
    public int Attempts;
}

// Per-operation accumulator. Held in ctx.Out for the life of one call, the
// same place metrics keeps its start marker.
public class CostPending
{
    public int Attempts;
    public double Amount;
    public double Reported;
    public double Estimated;
    public string Source = "none";

    // Set by PrePoint. Its absence means the call never entered the
    // pipeline (direct/graphql), so Charge commits the spend itself.
    public bool Piped;
}

public class CostTotal
{
    public int Calls;
    public int Attempts;
    public double Amount;
    public double Reported;
    public double Estimated;
}

public class CostBudget
{
    public double Limit;
    public double Spent;
    public double Remaining;
    public bool Exceeded;
}

public class CostFeature : BaseFeature
{
    private UnivecSDK? _client;
    private Dictionary<string, object?>? _options;
    private int _seq;

    // Aggregates (mirrors the ts client._cost record).
    public string Currency = "USD";
    public CostTotal Total = new();
    public Dictionary<string, CostBucket> Ops = new();
    public Dictionary<string, CostBucket> Actors = new();
    public CostBudget Budget = new();
    public CostRecord? Last;

    private const string PendingKey = "cost_pending";

    public CostFeature()
    {
        Version = "0.0.1";
        Name = "cost";
        Active = true;
    }

    public override void Init(Context ctx, Dictionary<string, object?> options)
    {
        _client = ctx.Client;
        _options = options;
        Active = FoptBool(options, "active", false);
        _seq = 0;

        Currency = FoptStr(options, "currency", "USD");
        Total = new CostTotal();
        Ops = new Dictionary<string, CostBucket>();
        Actors = new Dictionary<string, CostBucket>();
        var limit = Limit();
        Budget = new CostBudget { Limit = limit, Remaining = limit };
        Last = null;

        if (!Active)
        {
            return;
        }

        var inner = ctx.Utility!.Fetcher;

        ctx.Utility.Fetcher = (ctx2, url, fetchdef) => Charge(ctx2, url, fetchdef, inner);
    }

    // Budget gate. Runs before endpoint resolution, so a refused call costs
    // nothing at all.
    public override void PrePoint(Context ctx)
    {
        if (!Active)
        {
            return;
        }

        // Mark the context as running through the pipeline, so Charge knows
        // a PreDone is coming and does not commit the spend itself.
        var pending = Pending(ctx);
        pending.Piped = true;

        var limit = Limit();
        if (limit <= 0)
        {
            return;
        }

        if (Total.Amount < limit)
        {
            return;
        }

        Budget.Exceeded = true;

        if (FoptStr(_options, "onBudget", "warn") != "deny")
        {
            return;
        }

        var err = ctx.MakeError("cost_budget",
            "Cost budget of " + limit + " " + Currency + " is spent (" +
            Total.Amount + " " + Currency + " used)");

        // Short-circuit endpoint resolution; MakePoint surfaces this error
        // before any network activity.
        ctx.Out["point"] = err;
    }

    private object? Charge(Context ctx, string url, Dictionary<string, object?> fetchdef,
        FetcherFunc inner)
    {
        object? res = null;
        Exception? err = null;

        // A throwing transport still costs an attempt. Without this, a run
        // of connection-level failures under `retry` (which catches the
        // throw and tries again) would be charged nothing at all, and an
        // onBudget = "deny" ceiling could never stop it.
        try
        {
            res = inner(ctx, url, fetchdef);
        }
        catch (Exception ex)
        {
            err = ex;
        }

        var (amount, source) = Price(ctx, res);

        var pending = Pending(ctx);
        pending.Attempts++;

        // Accumulated here, committed once at PreDone. Adding each attempt
        // to the running total and then subtracting it again when a body
        // figure supersedes it loses precision to catastrophic cancellation
        // (5 + (0.01 - 5) is not 0.01 in binary floating point).
        //
        // Reported and estimated are kept apart per ATTEMPT, not per
        // operation: a 503 priced from the rate table followed by a 200
        // carrying the cost header is part estimate, part reported, and
        // collapsing both into the final attempt's category would corrupt
        // the split.
        pending.Amount += amount;
        if (source == "header" || source == "body")
        {
            pending.Reported += amount;
        }
        else
        {
            pending.Estimated += amount;
        }
        pending.Source = source;

        Total.Attempts++;

        // Direct() and Graphql() reach the transport without dispatching
        // any pipeline hooks - no PrePoint to gate on, and no PreDone to
        // commit. Their spend is committed here instead, or it would never
        // be counted and could run past an onBudget = "deny" ceiling
        // indefinitely. Piped is set by PrePoint, so its absence is the
        // signal.
        if (!pending.Piped)
        {
            Commit(ctx, pending, "_", "direct");
            ctx.Out.Remove(PendingKey);
        }

        if (err != null)
        {
            throw err;
        }

        return res;
    }

    private CostPending Pending(Context ctx)
    {
        if (ctx.Out.TryGetValue(PendingKey, out var raw) && raw is CostPending p)
        {
            return p;
        }
        var pending = new CostPending();
        ctx.Out[PendingKey] = pending;
        return pending;
    }

    // Attribute the operation's spend once the call is finished.
    public override void PreDone(Context ctx)
    {
        Finish(ctx, true);
    }

    // A failed operation still spent the money. When the pipeline errors,
    // PreDone never runs, so without this the attempts are counted and the
    // spend is not, and a budget could never see the cost of a failed call.
    // Whichever hook fires first consumes the pending entry, so it commits
    // exactly once.
    public override void PreUnexpected(Context ctx)
    {
        Finish(ctx, false);
    }

    private void Finish(Context ctx, bool done)
    {
        if (!Active)
        {
            return;
        }
        if (!ctx.Out.TryGetValue(PendingKey, out var raw) || raw is not CostPending pending)
        {
            return;
        }
        ctx.Out.Remove(PendingKey);

        // A FAILED operation that made no attempt never reached the network:
        // PrePoint creates the pending entry to mark the context as piped,
        // and then the budget gate refuses the call (rbac, or an
        // unresolvable endpoint, short-circuits just as early). Committing
        // it would count a call that never happened and file a zero-amount
        // record as Last.
        //
        // A SUCCEEDED operation that made no attempt is the opposite case:
        // it was served from the cache. That is a real call, and the fact
        // that it cost nothing is the whole point of ordering cost inside
        // the cache.
        if (!done && pending.Attempts == 0)
        {
            return;
        }

        var entity = ctx.Op?.Entity ?? "_";
        var opname = ctx.Op?.Name ?? "_";
        if (entity == "")
        {
            entity = "_";
        }
        if (opname == "")
        {
            opname = "_";
        }

        Commit(ctx, pending, entity, opname);
    }

    // Commit one operation's spend: totals, budget, per-op and per-actor
    // attribution, and the record. Shared by Finish and the raw-request
    // path in Charge, which has no PreDone to reach.
    private void Commit(Context ctx, CostPending pending, string entity, string opname)
    {
        var amount = pending.Amount;
        var reported = pending.Reported;
        var estimated = pending.Estimated;
        var source = pending.Source;

        // A body figure prices the whole call, so it replaces the
        // per-attempt estimate rather than adding to it - and, being
        // server-stated, the whole amount counts as reported.
        var (body, hasBody) = Body(ctx);
        if (hasBody)
        {
            amount = body;
            reported = body;
            estimated = 0;
            source = "body";
        }

        Spend(amount, reported, estimated);

        var actor = FoptStr(_options, "actor", "");
        if (ctx.Ctrl != null && ctx.Ctrl.Actor != "")
        {
            actor = ctx.Ctrl.Actor;
        }
        if (actor == "")
        {
            actor = "anonymous";
        }

        Total.Calls++;
        Bump(Ops, entity + "." + opname, amount);
        Bump(Actors, actor, amount);

        _seq++;
        Last = new CostRecord
        {
            Seq = _seq,
            Entity = entity,
            Op = opname,
            Actor = actor,
            Amount = amount,
            Currency = Currency,
            Source = source,
            Attempts = pending.Attempts,
        };

        if (Opt(_options, "sink") is Action<CostRecord> sink)
        {
            try
            {
                sink(Last);
            }
            catch (Exception)
            {
                // A sink must never break the call it is reporting on.
            }
        }
    }

    // Price one attempt: a reported header figure, else the rate table,
    // else the flat unit.
    private (double, string) Price(Context ctx, object? res)
    {
        var header = FoptStr(_options, "header", "");
        if (header != "")
        {
            var (v, has) = HeaderNum(res, header);
            if (has)
            {
                return (v * PerUnit(), "header");
            }
        }

        var (rate, hasRate) = Rate(ctx);
        if (hasRate)
        {
            return (rate, "table");
        }

        var unit = FoptNum(_options, "unit", 0);
        if (unit != 0)
        {
            return (unit, "unit");
        }

        return (0, "none");
    }

    // The rate table uses the same lookup grammar as rbac's rules:
    // '<entity>.<op>', then '<op>', then '*'.
    private (double, bool) Rate(Context ctx)
    {
        var rates = FoptMap(_options, "rates");
        if (rates == null)
        {
            return (0, false);
        }

        var entity = ctx.Entity?.GetName() ?? ctx.Op?.Entity ?? "";
        var opname = ctx.Op?.Name ?? "";

        foreach (var key in new[] { entity + "." + opname, opname, "*" })
        {
            if (rates.TryGetValue(key, out var r))
            {
                var (n, has) = ToNum(r);
                if (has)
                {
                    return (n, true);
                }
            }
        }
        return (0, false);
    }

    // A usage figure from the parsed result body, priced by perUnit. Read
    // here, not at the transport seam, because the body is consumed once.
    private (double, bool) Body(Context ctx)
    {
        var path = FoptStr(_options, "path", "");
        if (path == "" || ctx.Result == null)
        {
            return (0, false);
        }
        if (ctx.Result.Body is not Dictionary<string, object?> body)
        {
            return (0, false);
        }
        var v = StructUtils.GetPath(body, path);
        var (n, has) = ToNum(v);
        if (!has)
        {
            return (0, false);
        }
        return (n * PerUnit(), true);
    }

    private void Spend(double amount, double reported, double estimated)
    {
        Total.Amount += amount;
        Total.Reported += reported;
        Total.Estimated += estimated;

        Budget.Spent = Total.Amount;
        if (Budget.Limit > 0)
        {
            Budget.Remaining = Math.Max(0, Budget.Limit - Total.Amount);
            if (Total.Amount >= Budget.Limit)
            {
                Budget.Exceeded = true;
            }
        }
        else
        {
            Budget.Remaining = 0;
        }
    }

    private static void Bump(Dictionary<string, CostBucket> bucket, string key, double amount)
    {
        if (!bucket.TryGetValue(key, out var b))
        {
            b = new CostBucket();
            bucket[key] = b;
        }
        b.Calls++;
        b.Amount += amount;
    }

    // HTTP header names are case-insensitive and a custom transport keeps
    // conventional casing ("X-Request-Cost"), so FresHeader scans rather
    // than indexes.
    private static (double, bool) HeaderNum(object? res, string name)
    {
        var (v, has) = FresHeader(res, name);
        if (!has)
        {
            return (0, false);
        }
        return double.TryParse(v.Trim(),
            System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture, out var n)
            ? (n, true)
            : (0, false);
    }

    private static (double, bool) ToNum(object? v)
    {
        return v switch
        {
            int n => (n, true),
            long n => (n, true),
            double n => (n, true),
            float n => (n, true),
            short n => (n, true),
            byte n => (n, true),
            _ => (0, false),
        };
    }

    private double PerUnit()
    {
        return FoptNum(_options, "perUnit", 0);
    }

    private double Limit()
    {
        return FoptNum(_options, "budget", 0);
    }
}
