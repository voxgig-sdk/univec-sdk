// Network behaviour simulation. Wraps the active transport (the live
// HttpClient fetch or the `test` feature's in-memory mock) and injects
// realistic network conditions so offline unit tests can exercise slowness,
// transient failures, rate limiting and outages deterministically.
//
// Every injection mode is counter-driven (per client instance) so tests
// are reproducible without mocking timers. `failRate` adds optional
// pseudo-random failures via a seeded LCG for coverage-style testing.

using static UnivecSdk.Feature.FeatureOptions;

namespace UnivecSdk.Feature;

public class NetsimFeature : BaseFeature
{
    private UnivecSDK? _client;
    private Dictionary<string, object?>? _options;
    private long _seed;

    // Activity tracking (mirrors the ts client._netsim record).
    public int Calls;
    public List<Dictionary<string, object?>> Applied = new();

    public NetsimFeature()
    {
        Version = "0.0.1";
        Name = "netsim";
        Active = true;
    }

    public override void Init(Context ctx, Dictionary<string, object?> options)
    {
        _client = ctx.Client;
        _options = options;
        Active = FoptBool(options, "active", false);

        _seed = FoptInt(_options, "seed", 0);
        if (_seed == 0)
        {
            _seed = 1;
        }

        if (!Active)
        {
            return;
        }

        var inner = ctx.Utility!.Fetcher;

        ctx.Utility.Fetcher = (ctx2, url, fetchdef) => Simulate(ctx2, url, fetchdef, inner);
    }

    private object? Simulate(Context ctx, string url, Dictionary<string, object?> fetchdef,
        FetcherFunc inner)
    {
        var opts = _options;
        Calls++;
        var call = Calls;

        // Record the simulated conditions for test/debug inspection.
        var applied = new Dictionary<string, object?>();

        // Total outage: every call fails at the transport level.
        if (FoptBool(opts, "offline", false))
        {
            SleepMs(PickLatency());
            applied["offline"] = true;
            Track(ctx, applied);
            throw ctx.MakeError("netsim_offline",
                "Simulated network offline (URL was: \"" + url + "\")");
        }

        // Connection-level errors for the first N calls (e.g. ECONNRESET).
        if (call <= FoptInt(opts, "errorTimes", 0))
        {
            SleepMs(PickLatency());
            applied["error"] = true;
            Track(ctx, applied);
            throw ctx.MakeError("netsim_conn",
                $"Simulated connection error (call {call})");
        }

        // Rate-limit responses (HTTP 429 + Retry-After) for the first N calls.
        if (call <= FoptInt(opts, "rateLimitTimes", 0))
        {
            SleepMs(PickLatency());
            applied["rateLimited"] = true;
            Track(ctx, applied);
            return Respond(429, null, new Dictionary<string, object?>
            {
                ["statusText"] = "Too Many Requests",
                ["headers"] = new Dictionary<string, object?>
                {
                    ["retry-after"] = FoptInt(opts, "retryAfter", 0).ToString(),
                },
            });
        }

        // Retryable failure status for the first N calls, or every Nth call,
        // or pseudo-randomly at `failRate`.
        var failStatus = FoptInt(opts, "failStatus", 503);
        var failEvery = FoptInt(opts, "failEvery", 0);
        var failByCount = call <= FoptInt(opts, "failTimes", 0);
        var failByEvery = failEvery > 0 && call % failEvery == 0;
        var failRate = FoptNum(opts, "failRate", 0);
        var failByRate = failRate > 0 && Rand() < failRate;
        if (failByCount || failByEvery || failByRate)
        {
            SleepMs(PickLatency());
            applied["failStatus"] = failStatus;
            Track(ctx, applied);
            return Respond(failStatus, null, new Dictionary<string, object?>
            {
                ["statusText"] = "Simulated Failure",
            });
        }

        // Otherwise: apply latency then delegate to the real transport.
        var latency = PickLatency();
        applied["latency"] = latency;
        Track(ctx, applied);
        SleepMs(latency);
        return inner(ctx, url, fetchdef);
    }

    // PickLatency yields ms: a fixed number, or a uniform sample from {min,max}.
    private int PickLatency()
    {
        var l = Opt(_options, "latency");
        if (l == null)
        {
            return 0;
        }
        if (l is Dictionary<string, object?> lm)
        {
            var min = FoptInt(lm, "min", 0);
            var max = FoptInt(lm, "max", min);
            if (max <= min)
            {
                return min;
            }
            return min + (int)(Rand() * (max - min));
        }
        var fixedMs = FoptInt(_options, "latency", 0);
        return fixedMs < 0 ? 0 : fixedMs;
    }

    private void SleepMs(int ms)
    {
        if (ms <= 0)
        {
            return;
        }
        FoptSleep(_options)(ms);
    }

    // Rand yields a deterministic 0..1 pseudo-random via a linear
    // congruential generator.
    private double Rand()
    {
        _seed = (_seed * 1103515245 + 12345) & 0x7fffffff;
        return _seed / (double)0x7fffffff;
    }

    private void Track(Context ctx, Dictionary<string, object?> applied)
    {
        Applied.Add(applied);
        if (ctx.Ctrl?.Explain != null)
        {
            ctx.Ctrl.Explain["netsim"] = new Dictionary<string, object?>
            {
                ["calls"] = Calls,
                ["applied"] = Applied.Cast<object?>().ToList(),
            };
        }
    }

    // Respond builds a transport-shaped response (matching the test
    // feature's mock) that the result pipeline understands.
    private static Dictionary<string, object?> Respond(int status, object? data,
        Dictionary<string, object?>? extra)
    {
        var res = new Dictionary<string, object?>
        {
            ["status"] = status,
            ["statusText"] = "OK",
            ["json"] = (Func<object?>)(() => data),
            ["body"] = "not-used",
            ["headers"] = new Dictionary<string, object?>(),
        };
        if (extra != null)
        {
            foreach (var kv in extra)
            {
                res[kv.Key] = kv.Value;
            }
        }
        return res;
    }
}
