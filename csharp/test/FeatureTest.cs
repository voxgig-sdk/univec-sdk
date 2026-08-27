// Behavioural tests for the enterprise features shipped with this SDK
// (retry, cache, rbac, telemetry, ...). Each block runs only when its
// feature is present (see Fh.HasFeature in FeatureHarness.cs, which also
// holds the Fh* pipeline harness these tests drive).
//
// This file constructs every shipped feature type by name, so it only
// compiles with the COMPLETE feature set - it is listed in the csharp
// target's `feature.fullset` and dropped when a project trims its features.

using System.Text.RegularExpressions;

using Voxgig.Struct;
using Xunit;

using UnivecSdk;
using UnivecSdk.Feature;

namespace UnivecSdk.Test;

// --- netsim -----------------------------------------------------------------

public class FeatureNetsimTest
{
    [Fact]
    public void FixedLatencyThenDelegate()
    {
        if (Fh.SkipWithout("netsim")) return;
        var clock = new FhClock();
        var f = new NetsimFeature();
        var h = Fh.Make(null, (f, new Dictionary<string, object?>
        {
            ["latency"] = 250,
            ["sleep"] = (Action<int>)clock.Sleep,
        }));
        var res = h.Op(new FhOpSpec
        {
            Op = "load",
            Ctrl = new Dictionary<string, object?>
            {
                ["explain"] = new Dictionary<string, object?>(),
            },
        });
        Assert.True(res.Ok, $"expected ok, got err: {res.Err}");
        Assert.Equal(250, clock.T);
        Assert.Equal(1, f.Calls);
    }

    [Fact]
    public void RangedLatencyInMinMax()
    {
        if (Fh.SkipWithout("netsim")) return;
        var clock = new FhClock();
        var f = new NetsimFeature();
        var h = Fh.Make(null, (f, new Dictionary<string, object?>
        {
            ["latency"] = new Dictionary<string, object?> { ["min"] = 100, ["max"] = 300 },
            ["seed"] = 7,
            ["sleep"] = (Action<int>)clock.Sleep,
        }));
        h.Op(new FhOpSpec { Op = "load" });
        Assert.True(clock.T >= 100 && clock.T < 300,
            $"expected latency in [100,300), got {clock.T}");
    }

    [Fact]
    public void EqualMinMaxLatencyExact()
    {
        if (Fh.SkipWithout("netsim")) return;
        var clock = new FhClock();
        var f = new NetsimFeature();
        var h = Fh.Make(null, (f, new Dictionary<string, object?>
        {
            ["latency"] = new Dictionary<string, object?> { ["min"] = 50, ["max"] = 50 },
            ["sleep"] = (Action<int>)clock.Sleep,
        }));
        h.Op(new FhOpSpec { Op = "load" });
        Assert.Equal(50, clock.T);
    }

    [Fact]
    public void FailTimesReturnsRetryableStatus()
    {
        if (Fh.SkipWithout("netsim")) return;
        var f = new NetsimFeature();
        var h = Fh.Make(null, (f, new Dictionary<string, object?>
        {
            ["failTimes"] = 2,
            ["failStatus"] = 503,
        }));
        Assert.Equal(503, h.Op(new FhOpSpec { Op = "load" }).Result!.Status);
        Assert.Equal(503, h.Op(new FhOpSpec { Op = "load" }).Result!.Status);
        var res = h.Op(new FhOpSpec { Op = "load" });
        Assert.True(res.Ok, $"expected third call to succeed, got err: {res.Err}");
    }

    [Fact]
    public void FailEveryFailsEveryNth()
    {
        if (Fh.SkipWithout("netsim")) return;
        var f = new NetsimFeature();
        var h = Fh.Make(null, (f, new Dictionary<string, object?> { ["failEvery"] = 2 }));
        Assert.True(h.Op(new FhOpSpec { Op = "load" }).Ok, "call 1 should succeed");
        Assert.False(h.Op(new FhOpSpec { Op = "load" }).Ok, "call 2 should fail");
        Assert.True(h.Op(new FhOpSpec { Op = "load" }).Ok, "call 3 should succeed");
    }

    [Fact]
    public void FailRateWithSeedDeterministic()
    {
        if (Fh.SkipWithout("netsim")) return;
        var f = new NetsimFeature();
        var h = Fh.Make(null, (f, new Dictionary<string, object?>
        {
            ["failRate"] = 1,
            ["seed"] = 5,
        }));
        Assert.False(h.Op(new FhOpSpec { Op = "load" }).Ok, "expected deterministic failure");
    }

    [Fact]
    public void ErrorTimesConnectionError()
    {
        if (Fh.SkipWithout("netsim")) return;
        var f = new NetsimFeature();
        var h = Fh.Make(null, (f, new Dictionary<string, object?> { ["errorTimes"] = 1 }));
        var res = h.Op(new FhOpSpec { Op = "load" });
        Assert.Equal("netsim_conn", Fh.ErrCode(res.Err));
    }

    [Fact]
    public void OfflineFailsEveryCall()
    {
        if (Fh.SkipWithout("netsim")) return;
        var f = new NetsimFeature();
        var h = Fh.Make(null, (f, new Dictionary<string, object?> { ["offline"] = true }));
        var res = h.Op(new FhOpSpec { Op = "load" });
        Assert.Equal("netsim_offline", Fh.ErrCode(res.Err));
    }

    [Fact]
    public void RateLimitTimes429RetryAfter()
    {
        if (Fh.SkipWithout("netsim")) return;
        var f = new NetsimFeature();
        var h = Fh.Make(null, (f, new Dictionary<string, object?>
        {
            ["rateLimitTimes"] = 1,
            ["retryAfter"] = 3,
        }));
        var res = h.Op(new FhOpSpec { Op = "load" });
        Assert.Equal(429, res.Result!.Status);
        Assert.Equal("3", res.Result.Headers["retry-after"]);
    }

    [Fact]
    public void InactiveDoesNotWrap()
    {
        if (Fh.SkipWithout("netsim")) return;
        var f = new NetsimFeature();
        var h = Fh.Make(null, (f, new Dictionary<string, object?>
        {
            ["active"] = false,
            ["offline"] = true,
        }));
        var res = h.Op(new FhOpSpec { Op = "load" });
        Assert.True(res.Ok, $"inactive netsim must not simulate: {res.Err}");
        Assert.Equal(0, f.Calls);
    }
}

// --- retry ------------------------------------------------------------------

public class FeatureRetryTest
{
    [Fact]
    public void RetriesTransientThenSucceeds()
    {
        if (Fh.SkipWithout("retry", "netsim")) return;
        var clock = new FhClock();
        var rf = new RetryFeature();
        var h = Fh.Make(null,
            (new NetsimFeature(), new Dictionary<string, object?>
            {
                ["failTimes"] = 2,
                ["failStatus"] = 503,
            }),
            (rf, new Dictionary<string, object?>
            {
                ["retries"] = 3,
                ["minDelay"] = 10,
                ["jitter"] = false,
                ["sleep"] = (Action<int>)clock.Sleep,
            }));
        var res = h.Op(new FhOpSpec { Op = "load" });
        Assert.True(res.Ok, $"expected success after retries: {res.Err}");
        Assert.Equal(2, rf.Attempts);
    }

    [Fact]
    public void GivesUpAfterBudget()
    {
        if (Fh.SkipWithout("retry", "netsim")) return;
        var clock = new FhClock();
        var rf = new RetryFeature();
        var h = Fh.Make(null,
            (new NetsimFeature(), new Dictionary<string, object?>
            {
                ["failTimes"] = 9,
                ["failStatus"] = 500,
            }),
            (rf, new Dictionary<string, object?>
            {
                ["retries"] = 2,
                ["minDelay"] = 1,
                ["jitter"] = false,
                ["sleep"] = (Action<int>)clock.Sleep,
            }));
        var res = h.Op(new FhOpSpec { Op = "load" });
        Assert.Equal(500, res.Result!.Status);
    }

    [Fact]
    public void DoesNotRetryNonRetryableStatus()
    {
        if (Fh.SkipWithout("retry")) return;
        var rec = new FhRecorder
        {
            Reply = (_, _) => Fh.Response(404, null, null),
        };
        var h = Fh.Make(rec.Fetch, (new RetryFeature(), new Dictionary<string, object?>
        {
            ["retries"] = 3,
            ["minDelay"] = 0,
        }));
        h.Op(new FhOpSpec { Op = "load" });
        Assert.Single(rec.Calls);
    }

    [Fact]
    public void RetriesTransportErrorThenReturnsIt()
    {
        if (Fh.SkipWithout("retry")) return;
        var clock = new FhClock();
        var n = 0;
        FetcherFunc server = (ctx, _, _) =>
        {
            n++;
            throw ctx.MakeError("boom", "boom");
        };
        var h = Fh.Make(server, (new RetryFeature(), new Dictionary<string, object?>
        {
            ["retries"] = 2,
            ["minDelay"] = 1,
            ["jitter"] = false,
            ["sleep"] = (Action<int>)clock.Sleep,
        }));
        var res = h.Op(new FhOpSpec { Op = "load" });
        Assert.False(res.Ok, "expected failure");
        Assert.Equal(3, n);
    }

    [Fact]
    public void RetriesNullTransportResult()
    {
        if (Fh.SkipWithout("retry")) return;
        var n = 0;
        FetcherFunc server = (_, _, _) =>
        {
            n++;
            if (n < 2)
            {
                return null;
            }
            return Fh.Response(200, new Dictionary<string, object?> { ["ok"] = true }, null);
        };
        var h = Fh.Make(server, (new RetryFeature(), new Dictionary<string, object?>
        {
            ["retries"] = 3,
            ["minDelay"] = 0,
        }));
        var res = h.Op(new FhOpSpec { Op = "load" });
        Assert.True(res.Ok, $"expected success, got {res.Err}");
        Assert.Equal(2, n);
    }

    [Fact]
    public void HonoursServerRetryAfter()
    {
        if (Fh.SkipWithout("retry", "netsim")) return;
        var clock = new FhClock();
        var h = Fh.Make(null,
            (new NetsimFeature(), new Dictionary<string, object?>
            {
                ["rateLimitTimes"] = 1,
                ["retryAfter"] = 2,
            }),
            (new RetryFeature(), new Dictionary<string, object?>
            {
                ["retries"] = 2,
                ["minDelay"] = 10,
                ["maxDelay"] = 60000,
                ["jitter"] = false,
                ["sleep"] = (Action<int>)clock.Sleep,
            }));
        var res = h.Op(new FhOpSpec { Op = "load" });
        Assert.True(res.Ok, $"expected success: {res.Err}");
        Assert.Equal(2000, clock.T);
    }

    [Fact]
    public void InactiveDoesNotWrap()
    {
        if (Fh.SkipWithout("retry")) return;
        var rec = new FhRecorder
        {
            Reply = (_, _) => Fh.Response(503, null, null),
        };
        var h = Fh.Make(rec.Fetch,
            (new RetryFeature(), new Dictionary<string, object?> { ["active"] = false }));
        h.Op(new FhOpSpec { Op = "load" });
        Assert.Single(rec.Calls);
    }
}

// --- timeout ----------------------------------------------------------------

public class FeatureTimeoutTest
{
    [Fact]
    public void SlowRequestTimesOut()
    {
        if (Fh.SkipWithout("timeout")) return;
        FetcherFunc server = (_, _, _) =>
        {
            Thread.Sleep(60);
            return Fh.Response(200, new Dictionary<string, object?> { ["ok"] = true }, null);
        };
        var f = new TimeoutFeature();
        var h = Fh.Make(server, (f, new Dictionary<string, object?> { ["ms"] = 10 }));
        var res = h.Op(new FhOpSpec { Op = "load" });
        Assert.Equal("timeout", Fh.ErrCode(res.Err));
        Assert.Equal(1, f.Count);
    }

    [Fact]
    public void FastRequestPasses()
    {
        if (Fh.SkipWithout("timeout")) return;
        var h = Fh.Make(null,
            (new TimeoutFeature(), new Dictionary<string, object?> { ["ms"] = 1000 }));
        var res = h.Op(new FhOpSpec { Op = "load" });
        Assert.True(res.Ok, $"expected success: {res.Err}");
    }

    [Fact]
    public void MsZeroDisables()
    {
        if (Fh.SkipWithout("timeout")) return;
        var h = Fh.Make(null,
            (new TimeoutFeature(), new Dictionary<string, object?> { ["ms"] = 0 }));
        var res = h.Op(new FhOpSpec { Op = "load" });
        Assert.True(res.Ok, $"expected success: {res.Err}");
    }

    [Fact]
    public void InactiveDoesNotWrap()
    {
        if (Fh.SkipWithout("timeout")) return;
        var h = Fh.Make(null,
            (new TimeoutFeature(), new Dictionary<string, object?> { ["active"] = false }));
        var res = h.Op(new FhOpSpec { Op = "load" });
        Assert.True(res.Ok, $"expected success: {res.Err}");
    }
}

// --- ratelimit ----------------------------------------------------------------

public class FeatureRatelimitTest
{
    [Fact]
    public void ThrottlesOnceBurstSpent()
    {
        if (Fh.SkipWithout("ratelimit")) return;
        var clock = new FhClock();
        var f = new RatelimitFeature();
        var h = Fh.Make(null, (f, new Dictionary<string, object?>
        {
            ["rate"] = 1,
            ["burst"] = 2,
            ["now"] = (Func<long>)clock.Now,
            ["sleep"] = (Action<int>)clock.Sleep,
        }));
        h.Op(new FhOpSpec { Op = "load" });
        h.Op(new FhOpSpec { Op = "load" });
        h.Op(new FhOpSpec { Op = "load" });
        Assert.Equal(1, f.Throttled);
        Assert.True(clock.T > 0, "expected the clock to advance while throttled");
    }

    [Fact]
    public void BurstDefaultsToRateAndRefills()
    {
        if (Fh.SkipWithout("ratelimit")) return;
        var clock = new FhClock();
        var f = new RatelimitFeature();
        var h = Fh.Make(null, (f, new Dictionary<string, object?>
        {
            ["rate"] = 2,
            ["now"] = (Func<long>)clock.Now,
            ["sleep"] = (Action<int>)clock.Sleep,
        }));
        h.Op(new FhOpSpec { Op = "load" });
        h.Op(new FhOpSpec { Op = "load" });
        clock.Advance(1000); // refill
        h.Op(new FhOpSpec { Op = "load" });
        Assert.Equal(0, f.Throttled);
    }

    [Fact]
    public void InactiveDoesNotWrap()
    {
        if (Fh.SkipWithout("ratelimit")) return;
        var f = new RatelimitFeature();
        var h = Fh.Make(null,
            (f, new Dictionary<string, object?> { ["active"] = false }));
        var res = h.Op(new FhOpSpec { Op = "load" });
        Assert.True(res.Ok, $"expected success: {res.Err}");
        Assert.Equal(0, f.Throttled);
    }
}

// --- cache --------------------------------------------------------------------

public class FeatureCacheTest
{
    [Fact]
    public void ServesRepeatedReadFromCache()
    {
        if (Fh.SkipWithout("cache")) return;
        var rec = new FhRecorder();
        var f = new CacheFeature();
        var h = Fh.Make(rec.Fetch, (f, new Dictionary<string, object?> { ["ttl"] = 10000 }));
        var a = h.Op(new FhOpSpec { Op = "load", Path = "/w/1" });
        var b = h.Op(new FhOpSpec { Op = "load", Path = "/w/1" });
        Assert.Single(rec.Calls);
        Assert.True(StructRunner.DeepEqual(a.Data, b.Data),
            $"expected identical cached data: {a.Data} != {b.Data}");
        Assert.Equal(1, f.Hit);
    }

    [Fact]
    public void DoesNotCacheNonGet()
    {
        if (Fh.SkipWithout("cache")) return;
        var rec = new FhRecorder();
        var h = Fh.Make(rec.Fetch, (new CacheFeature(), null));
        h.Op(new FhOpSpec { Op = "create", Path = "/w" });
        h.Op(new FhOpSpec { Op = "create", Path = "/w" });
        Assert.Equal(2, rec.Calls.Count);
    }

    [Fact]
    public void DoesNotCacheNon2xx()
    {
        if (Fh.SkipWithout("cache")) return;
        var rec = new FhRecorder
        {
            Reply = (_, _) => Fh.Response(500, null, null),
        };
        var f = new CacheFeature();
        var h = Fh.Make(rec.Fetch, (f, null));
        h.Op(new FhOpSpec { Op = "load", Path = "/w" });
        h.Op(new FhOpSpec { Op = "load", Path = "/w" });
        Assert.Equal(2, rec.Calls.Count);
        Assert.Equal(2, f.Bypass);
    }

    [Fact]
    public void RefetchesAfterTtl()
    {
        if (Fh.SkipWithout("cache")) return;
        var clock = new FhClock();
        var rec = new FhRecorder();
        var h = Fh.Make(rec.Fetch, (new CacheFeature(), new Dictionary<string, object?>
        {
            ["ttl"] = 1000,
            ["now"] = (Func<long>)clock.Now,
        }));
        h.Op(new FhOpSpec { Op = "load", Path = "/w" });
        clock.Advance(1500);
        h.Op(new FhOpSpec { Op = "load", Path = "/w" });
        Assert.Equal(2, rec.Calls.Count);
    }

    [Fact]
    public void EvictsOldestPastMax()
    {
        if (Fh.SkipWithout("cache")) return;
        var rec = new FhRecorder();
        var h = Fh.Make(rec.Fetch, (new CacheFeature(), new Dictionary<string, object?>
        {
            ["ttl"] = 10000,
            ["max"] = 1,
        }));
        h.Op(new FhOpSpec { Op = "load", Path = "/a" });
        h.Op(new FhOpSpec { Op = "load", Path = "/b" }); // evicts /a
        h.Op(new FhOpSpec { Op = "load", Path = "/a" }); // miss again
        Assert.Equal(3, rec.Calls.Count);
    }

    [Fact]
    public void InactiveDoesNotWrap()
    {
        if (Fh.SkipWithout("cache")) return;
        var rec = new FhRecorder();
        var h = Fh.Make(rec.Fetch,
            (new CacheFeature(), new Dictionary<string, object?> { ["active"] = false }));
        h.Op(new FhOpSpec { Op = "load", Path = "/x" });
        h.Op(new FhOpSpec { Op = "load", Path = "/x" });
        Assert.Equal(2, rec.Calls.Count);
    }
}

// --- idempotency ----------------------------------------------------------------

public class FeatureIdempotencyTest
{
    [Fact]
    public void AddsKeyToMutatingOps()
    {
        if (Fh.SkipWithout("idempotency")) return;
        var rec = new FhRecorder();
        var h = Fh.Make(rec.Fetch, (new IdempotencyFeature(), null));
        h.Op(new FhOpSpec { Op = "create", Path = "/w" });
        Assert.True(rec.Headers(0).ContainsKey("Idempotency-Key"),
            "expected Idempotency-Key header on create");
    }

    [Fact]
    public void AddsKeyByHttpMethod()
    {
        if (Fh.SkipWithout("idempotency")) return;
        var rec = new FhRecorder();
        var h = Fh.Make(rec.Fetch, (new IdempotencyFeature(), null));
        h.Op(new FhOpSpec { Op = "act", Method = "PUT", Path = "/w" });
        Assert.True(rec.Headers(0).ContainsKey("Idempotency-Key"),
            "expected Idempotency-Key header on PUT");
    }

    [Fact]
    public void LeavesReadsUntouched()
    {
        if (Fh.SkipWithout("idempotency")) return;
        var rec = new FhRecorder();
        var h = Fh.Make(rec.Fetch, (new IdempotencyFeature(), null));
        h.Op(new FhOpSpec { Op = "load", Path = "/w/1" });
        Assert.False(rec.Headers(0).ContainsKey("Idempotency-Key"),
            "expected no Idempotency-Key header on load");
    }

    [Fact]
    public void PreservesCallerKeyCustomHeader()
    {
        if (Fh.SkipWithout("idempotency")) return;
        var rec = new FhRecorder();
        var h = Fh.Make(rec.Fetch, (new IdempotencyFeature(),
            new Dictionary<string, object?> { ["header"] = "X-Idem" }));
        h.Op(new FhOpSpec
        {
            Op = "create",
            Path = "/w",
            Headers = new Dictionary<string, object?> { ["X-Idem"] = "caller-1" },
        });
        Assert.Equal("caller-1", rec.Headers(0)["X-Idem"]);
    }

    [Fact]
    public void InjectedKeygen()
    {
        if (Fh.SkipWithout("idempotency")) return;
        var rec = new FhRecorder();
        var f = new IdempotencyFeature();
        var h = Fh.Make(rec.Fetch, (f, new Dictionary<string, object?>
        {
            ["keygen"] = (Func<string>)(() => "K1"),
        }));
        h.Op(new FhOpSpec { Op = "create", Path = "/w" });
        Assert.Equal("K1", rec.Headers(0)["Idempotency-Key"]);
        Assert.Equal("K1", f.Last);
        Assert.Equal(1, f.Issued);
    }

    [Fact]
    public void InactiveIsNoop()
    {
        if (Fh.SkipWithout("idempotency")) return;
        var rec = new FhRecorder();
        var h = Fh.Make(rec.Fetch,
            (new IdempotencyFeature(), new Dictionary<string, object?> { ["active"] = false }));
        h.Op(new FhOpSpec { Op = "create", Path = "/w" });
        Assert.False(rec.Headers(0).ContainsKey("Idempotency-Key"),
            "inactive idempotency must not add a key");
    }
}

// --- rbac -----------------------------------------------------------------------

public class FeatureRbacTest
{
    [Fact]
    public void DeniesBeforeAnyCall()
    {
        if (Fh.SkipWithout("rbac")) return;
        var rec = new FhRecorder();
        var f = new RbacFeature();
        var h = Fh.Make(rec.Fetch, (f, new Dictionary<string, object?>
        {
            ["rules"] = new Dictionary<string, object?> { ["widget.remove"] = "admin" },
            ["permissions"] = new List<object?>(),
        }));
        var res = h.Op(new FhOpSpec { Op = "remove", Path = "/w/1" });
        Assert.Equal("rbac_denied", Fh.ErrCode(res.Err));
        Assert.Empty(rec.Calls);
        Assert.Equal(1, f.Denied);
    }

    [Fact]
    public void AllowsHeldPermission()
    {
        if (Fh.SkipWithout("rbac")) return;
        var h = Fh.Make(null, (new RbacFeature(), new Dictionary<string, object?>
        {
            ["rules"] = new Dictionary<string, object?> { ["widget.remove"] = "admin" },
            ["permissions"] = new List<object?> { "admin" },
        }));
        var res = h.Op(new FhOpSpec { Op = "remove", Path = "/w/1" });
        Assert.True(res.Ok, $"expected allow: {res.Err}");
    }

    [Fact]
    public void OpRuleAndWildcardGrant()
    {
        if (Fh.SkipWithout("rbac")) return;
        var h = Fh.Make(null, (new RbacFeature(), new Dictionary<string, object?>
        {
            ["rules"] = new Dictionary<string, object?> { ["load"] = "read" },
            ["permissions"] = new List<object?> { "*" },
        }));
        var res = h.Op(new FhOpSpec { Op = "load" });
        Assert.True(res.Ok, $"expected wildcard grant: {res.Err}");
    }

    [Fact]
    public void DefaultAllowAndDenyTrue()
    {
        if (Fh.SkipWithout("rbac")) return;
        var allow = Fh.Make(null, (new RbacFeature(), new Dictionary<string, object?>
        {
            ["permissions"] = new List<object?>(),
        }));
        var resAllow = allow.Op(new FhOpSpec { Op = "load" });
        Assert.True(resAllow.Ok, $"expected default allow: {resAllow.Err}");

        var deny = Fh.Make(null, (new RbacFeature(), new Dictionary<string, object?>
        {
            ["deny"] = true,
            ["permissions"] = new List<object?>(),
        }));
        var resDeny = deny.Op(new FhOpSpec { Op = "load" });
        Assert.Equal("rbac_denied", Fh.ErrCode(resDeny.Err));
    }

    [Fact]
    public void InactiveIsNoop()
    {
        if (Fh.SkipWithout("rbac")) return;
        var h = Fh.Make(null, (new RbacFeature(), new Dictionary<string, object?>
        {
            ["active"] = false,
            ["deny"] = true,
        }));
        var res = h.Op(new FhOpSpec { Op = "load" });
        Assert.True(res.Ok, $"inactive rbac must not deny: {res.Err}");
    }
}

// --- metrics --------------------------------------------------------------------

public class FeatureMetricsTest
{
    [Fact]
    public void CountsOkAndErrPerOp()
    {
        if (Fh.SkipWithout("metrics", "netsim")) return;
        var f = new MetricsFeature();
        var h = Fh.Make(null,
            (new NetsimFeature(), new Dictionary<string, object?>
            {
                ["failTimes"] = 1,
                ["failStatus"] = 500,
            }),
            (f, null));
        h.Op(new FhOpSpec { Op = "load" });
        h.Op(new FhOpSpec { Op = "load" });
        h.Op(new FhOpSpec { Op = "list" });
        Assert.True(f.Total.Count == 3 && f.Total.Ok == 2 && f.Total.Err == 1,
            $"expected total 3/2/1, got {f.Total.Count}/{f.Total.Ok}/{f.Total.Err}");
        Assert.True(f.Ops.ContainsKey("widget.load") && f.Ops["widget.load"].Count == 2,
            "expected widget.load count 2");
    }

    [Fact]
    public void InjectedClock()
    {
        if (Fh.SkipWithout("metrics")) return;
        var clock = new FhClock();
        var f = new MetricsFeature();
        var h = Fh.Make(null, (f, new Dictionary<string, object?>
        {
            ["now"] = (Func<long>)clock.Now,
        }));
        h.Op(new FhOpSpec { Op = "load" });
        Assert.Equal(1, f.Total.Count);
        Assert.Equal(0, f.Total.TotalMs);
    }

    [Fact]
    public void InactiveRecordsNothing()
    {
        if (Fh.SkipWithout("metrics")) return;
        var f = new MetricsFeature();
        var h = Fh.Make(null, (f, new Dictionary<string, object?> { ["active"] = false }));
        h.Op(new FhOpSpec { Op = "load" });
        Assert.Equal(0, f.Total.Count);
    }
}

// --- telemetry ------------------------------------------------------------------

public class FeatureTelemetryTest
{
    [Fact]
    public void OpensSpansAndPropagatesHeaders()
    {
        if (Fh.SkipWithout("telemetry")) return;
        var rec = new FhRecorder();
        var exported = new List<Dictionary<string, object?>>();
        var f = new TelemetryFeature();
        var h = Fh.Make(rec.Fetch, (f, new Dictionary<string, object?>
        {
            ["exporter"] = (Action<Dictionary<string, object?>>)(s => exported.Add(s)),
        }));
        var res = h.Op(new FhOpSpec { Op = "load" });
        Assert.True(res.Ok, $"expected success: {res.Err}");
        Assert.True(f.Spans.Count == 1 && exported.Count == 1,
            $"expected 1 span + 1 export, got {f.Spans.Count}/{exported.Count}");
        var sent = rec.Headers(0);
        Assert.Equal(f.Spans[0]["traceId"], sent["X-Trace-Id"]);
        var traceparent = sent["traceparent"] as string ?? "";
        Assert.Matches(new Regex(@"^00-.+-.+-01$"), traceparent);
    }

    [Fact]
    public void RecordsFailedSpan()
    {
        if (Fh.SkipWithout("telemetry", "netsim")) return;
        var f = new TelemetryFeature();
        var h = Fh.Make(null,
            (new NetsimFeature(), new Dictionary<string, object?>
            {
                ["failTimes"] = 1,
                ["failStatus"] = 500,
            }),
            (f, null));
        h.Op(new FhOpSpec { Op = "load" });
        Assert.True(f.Spans.Count == 1 && Equals(f.Spans[0]["ok"], false),
            "expected 1 failed span");
    }

    [Fact]
    public void InjectedIdgenAndClock()
    {
        if (Fh.SkipWithout("telemetry")) return;
        var clock = new FhClock();
        var f = new TelemetryFeature();
        var h = Fh.Make(null, (f, new Dictionary<string, object?>
        {
            ["idgen"] = (Func<string, string>)(kind => kind + "-X"),
            ["now"] = (Func<long>)clock.Now,
        }));
        h.Op(new FhOpSpec { Op = "load" });
        Assert.Equal("trace-X", f.Spans[0]["traceId"]);
        Assert.Equal(0L, f.Spans[0]["durationMs"]);
    }

    [Fact]
    public void InactiveRecordsNothing()
    {
        if (Fh.SkipWithout("telemetry")) return;
        var f = new TelemetryFeature();
        var h = Fh.Make(null, (f, new Dictionary<string, object?> { ["active"] = false }));
        h.Op(new FhOpSpec { Op = "load" });
        Assert.Empty(f.Spans);
    }
}

// --- debug ----------------------------------------------------------------------

public class FeatureDebugTest
{
    [Fact]
    public void RedactsAndHonoursOnentryMax()
    {
        if (Fh.SkipWithout("debug")) return;
        var seen = new List<Dictionary<string, object?>>();
        var f = new DebugFeature();
        var h = Fh.Make(null, (f, new Dictionary<string, object?>
        {
            ["max"] = 1,
            ["onEntry"] = (Action<Dictionary<string, object?>>)(e => seen.Add(e)),
        }));
        h.Op(new FhOpSpec
        {
            Op = "load",
            Headers = new Dictionary<string, object?>
            {
                ["authorization"] = "Bearer secret",
            },
        });
        h.Op(new FhOpSpec { Op = "list" });
        Assert.Single(f.Entries);
        Assert.Equal(2, seen.Count);
        var headers = seen[0]["headers"] as Dictionary<string, object?>;
        Assert.Equal("<redacted>", headers?["authorization"]);
    }

    [Fact]
    public void CapturesFailures()
    {
        if (Fh.SkipWithout("debug", "netsim")) return;
        var f = new DebugFeature();
        var h = Fh.Make(null,
            (new NetsimFeature(), new Dictionary<string, object?>
            {
                ["failTimes"] = 1,
                ["failStatus"] = 500,
            }),
            (f, null));
        h.Op(new FhOpSpec { Op = "load" });
        Assert.True(f.Entries.Count == 1 && Equals(f.Entries[0]["ok"], false),
            "expected 1 failed entry");
    }

    [Fact]
    public void InjectedClockAndCustomRedact()
    {
        if (Fh.SkipWithout("debug")) return;
        var clock = new FhClock();
        var f = new DebugFeature();
        var h = Fh.Make(null, (f, new Dictionary<string, object?>
        {
            ["now"] = (Func<long>)clock.Now,
            ["redact"] = new List<object?> { "x-secret" },
        }));
        h.Op(new FhOpSpec
        {
            Op = "load",
            Headers = new Dictionary<string, object?>
            {
                ["x-secret"] = "hide",
                ["x-ok"] = "show",
            },
        });
        var headers = f.Entries[0]["headers"] as Dictionary<string, object?>;
        Assert.Equal("<redacted>", headers?["x-secret"]);
        Assert.Equal("show", headers?["x-ok"]);
    }

    [Fact]
    public void InactiveRecordsNothing()
    {
        if (Fh.SkipWithout("debug")) return;
        var f = new DebugFeature();
        var h = Fh.Make(null, (f, new Dictionary<string, object?> { ["active"] = false }));
        h.Op(new FhOpSpec { Op = "load" });
        Assert.Empty(f.Entries);
    }
}

// --- audit ----------------------------------------------------------------------

public class FeatureAuditTest
{
    [Fact]
    public void OneRecordPerOpSinkActor()
    {
        if (Fh.SkipWithout("audit", "netsim")) return;
        var sunk = new List<Dictionary<string, object?>>();
        var f = new AuditFeature();
        var h = Fh.Make(null,
            (new NetsimFeature(), new Dictionary<string, object?>
            {
                ["failTimes"] = 1,
                ["failStatus"] = 500,
            }),
            (f, new Dictionary<string, object?>
            {
                ["actor"] = "svc",
                ["max"] = 5,
                ["sink"] = (Action<Dictionary<string, object?>>)(r => sunk.Add(r)),
            }));
        h.Op(new FhOpSpec { Op = "remove", Path = "/w/1" });
        h.Op(new FhOpSpec
        {
            Op = "load",
            Ctrl = new Dictionary<string, object?> { ["actor"] = "per-call" },
        });
        Assert.Equal(2, f.Records.Count);
        Assert.Equal("error", f.Records[0]["outcome"]);
        Assert.Equal("svc", f.Records[0]["actor"]);
        Assert.Equal("per-call", f.Records[1]["actor"]);
        Assert.Equal(2, sunk.Count);
    }

    [Fact]
    public void DefaultActorAnonymous()
    {
        if (Fh.SkipWithout("audit")) return;
        var f = new AuditFeature();
        var h = Fh.Make(null, (f, null));
        h.Op(new FhOpSpec { Op = "load" });
        Assert.Equal("anonymous", f.Records[0]["actor"]);
    }

    [Fact]
    public void InjectedClock()
    {
        if (Fh.SkipWithout("audit")) return;
        var f = new AuditFeature();
        var h = Fh.Make(null, (f, new Dictionary<string, object?>
        {
            ["now"] = (Func<long>)(() => 42L),
        }));
        h.Op(new FhOpSpec { Op = "load" });
        Assert.Equal(42L, f.Records[0]["ts"]);
    }

    [Fact]
    public void InactiveRecordsNothing()
    {
        if (Fh.SkipWithout("audit")) return;
        var f = new AuditFeature();
        var h = Fh.Make(null, (f, new Dictionary<string, object?> { ["active"] = false }));
        h.Op(new FhOpSpec { Op = "load" });
        Assert.Empty(f.Records);
    }
}

// --- clienttrack ----------------------------------------------------------------

public class FeatureClienttrackTest
{
    [Fact]
    public void StableClientIdUniqueRequestIdsUa()
    {
        if (Fh.SkipWithout("clienttrack")) return;
        var rec = new FhRecorder();
        var f = new ClienttrackFeature();
        var h = Fh.Make(rec.Fetch, (f, new Dictionary<string, object?>
        {
            ["clientName"] = "Acme",
            ["clientVersion"] = "2.0.0",
        }));
        h.Op(new FhOpSpec { Op = "load" });
        h.Op(new FhOpSpec { Op = "load" });
        var h0 = rec.Headers(0);
        var h1 = rec.Headers(1);
        Assert.Equal("Acme/2.0.0", h0["User-Agent"]);
        Assert.Equal(h0["X-Client-Id"], h1["X-Client-Id"]);
        Assert.NotEqual(h0["X-Request-Id"], h1["X-Request-Id"]);
        Assert.Equal(2, f.Requests);
    }

    [Fact]
    public void DoesNotClobberCallerUa()
    {
        if (Fh.SkipWithout("clienttrack")) return;
        var rec = new FhRecorder();
        var h = Fh.Make(rec.Fetch, (new ClienttrackFeature(), null));
        h.Op(new FhOpSpec
        {
            Op = "load",
            Headers = new Dictionary<string, object?> { ["User-Agent"] = "mine" },
        });
        Assert.Equal("mine", rec.Headers(0)["User-Agent"]);
    }

    [Fact]
    public void InjectedIdgenFixedSession()
    {
        if (Fh.SkipWithout("clienttrack")) return;
        var rec = new FhRecorder();
        var h = Fh.Make(rec.Fetch, (new ClienttrackFeature(), new Dictionary<string, object?>
        {
            ["sessionId"] = "S1",
            ["idgen"] = (Func<string, string>)(kind => kind + "-1"),
        }));
        h.Op(new FhOpSpec { Op = "load" });
        Assert.Equal("S1", rec.Headers(0)["X-Client-Id"]);
        Assert.Equal("request-1", rec.Headers(0)["X-Request-Id"]);
    }

    [Fact]
    public void InactiveStampsNothing()
    {
        if (Fh.SkipWithout("clienttrack")) return;
        var rec = new FhRecorder();
        var h = Fh.Make(rec.Fetch,
            (new ClienttrackFeature(), new Dictionary<string, object?> { ["active"] = false }));
        h.Op(new FhOpSpec { Op = "load" });
        Assert.False(rec.Headers(0).ContainsKey("X-Client-Id"),
            "inactive clienttrack must not stamp headers");
    }
}

// --- paging ---------------------------------------------------------------------

public class FeaturePagingTest
{
    [Fact]
    public void StampsPageLimitAndReadsHeaders()
    {
        if (Fh.SkipWithout("paging")) return;
        var rec = new FhRecorder
        {
            Reply = (_, _) => Fh.Response(200, new Dictionary<string, object?>
            {
                ["items"] = new List<object?> { 1, 2 },
            }, new Dictionary<string, object?>
            {
                ["x-next-page"] = "2",
                ["x-total-count"] = "5",
                ["link"] = "</w?page=2>; rel=\"next\"",
            }),
        };
        var f = new PagingFeature();
        var h = Fh.Make(rec.Fetch, (f, new Dictionary<string, object?> { ["limit"] = 2 }));
        var res = h.Op(new FhOpSpec { Op = "list", Path = "/w" });
        Assert.Contains("page=1", rec.Url(0));
        Assert.Contains("limit=2", rec.Url(0));
        var paging = res.Result!.Paging!;
        Assert.Equal(2, UnivecSdk.Helpers.ToInt(paging["nextPage"]));
        Assert.Equal(5, UnivecSdk.Helpers.ToInt(paging["totalCount"]));
        Assert.Equal("/w?page=2", paging["next"]);
    }

    [Fact]
    public void BodyCursorAndExplicitCursor()
    {
        if (Fh.SkipWithout("paging")) return;
        var rec = new FhRecorder
        {
            Reply = (_, _) => Fh.Response(200, new Dictionary<string, object?>
            {
                ["nextCursor"] = "abc",
                ["hasMore"] = true,
            }, null),
        };
        var h = Fh.Make(rec.Fetch, (new PagingFeature(), null));
        var res = h.Op(new FhOpSpec
        {
            Op = "list",
            Path = "/w",
            Ctrl = new Dictionary<string, object?>
            {
                ["paging"] = new Dictionary<string, object?> { ["cursor"] = "xyz" },
            },
        });
        Assert.Contains("cursor=xyz", rec.Url(0));
        Assert.Equal("abc", res.Result!.Paging!["cursor"]);
        Assert.Equal(true, res.Result.Paging["hasMore"]);
    }

    [Fact]
    public void NonListNotPaged()
    {
        if (Fh.SkipWithout("paging")) return;
        var rec = new FhRecorder();
        var h = Fh.Make(rec.Fetch, (new PagingFeature(), null));
        h.Op(new FhOpSpec { Op = "load", Path = "/w/1" });
        Assert.DoesNotContain("page=", rec.Url(0));
    }

    [Fact]
    public void InactiveStampsNothing()
    {
        if (Fh.SkipWithout("paging")) return;
        var rec = new FhRecorder();
        var h = Fh.Make(rec.Fetch,
            (new PagingFeature(), new Dictionary<string, object?> { ["active"] = false }));
        h.Op(new FhOpSpec { Op = "list", Path = "/w" });
        Assert.DoesNotContain("page=", rec.Url(0));
    }
}

// --- streaming ------------------------------------------------------------------

public class FeatureStreamingTest
{
    [Fact]
    public void StreamsListItems()
    {
        if (Fh.SkipWithout("streaming")) return;
        var clock = new FhClock();
        var rec = new FhRecorder
        {
            Reply = (_, _) => Fh.Response(200,
                new List<object?> { "a", "b", "c" }, null),
        };
        var h = Fh.Make(rec.Fetch, (new StreamingFeature(), new Dictionary<string, object?>
        {
            ["chunkDelay"] = 5,
            ["sleep"] = (Action<int>)clock.Sleep,
        }));
        var res = h.Op(new FhOpSpec { Op = "list", Path = "/w" });
        Assert.True(res.Result!.Streaming, "expected streaming result");
        var seen = res.Result.Stream!().ToList();
        Assert.True(StructRunner.DeepEqual(seen, new List<object?> { "a", "b", "c" }),
            "expected streamed items");
        Assert.Equal(15, clock.T);
    }

    [Fact]
    public void BatchesWithChunksize()
    {
        if (Fh.SkipWithout("streaming")) return;
        var rec = new FhRecorder
        {
            Reply = (_, _) => Fh.Response(200,
                new List<object?> { 1, 2, 3, 4, 5 }, null),
        };
        var h = Fh.Make(rec.Fetch,
            (new StreamingFeature(), new Dictionary<string, object?> { ["chunkSize"] = 2 }));
        var res = h.Op(new FhOpSpec { Op = "list", Path = "/w" });
        var batches = res.Result!.Stream!().ToList();
        var want = new List<object?>
        {
            new List<object?> { 1, 2 },
            new List<object?> { 3, 4 },
            new List<object?> { 5 },
        };
        Assert.True(StructRunner.DeepEqual(batches, want),
            "expected chunked batches");
    }

    [Fact]
    public void NonListNotStreamed()
    {
        if (Fh.SkipWithout("streaming")) return;
        var h = Fh.Make(null, (new StreamingFeature(), null));
        var res = h.Op(new FhOpSpec { Op = "load" });
        Assert.False(res.Result!.Streaming || res.Result.Stream != null,
            "expected no stream on a non-list op");
    }

    [Fact]
    public void InactiveIsNoop()
    {
        if (Fh.SkipWithout("streaming")) return;
        var f = new StreamingFeature();
        var h = Fh.Make(null, (f, new Dictionary<string, object?> { ["active"] = false }));
        var res = h.Op(new FhOpSpec { Op = "list", Path = "/w" });
        Assert.False(res.Result!.Streaming, "inactive streaming must not attach");
        Assert.Equal(0, f.Opened);
    }
}

// --- proxy ----------------------------------------------------------------------

public class FeatureProxyTest
{
    [Fact]
    public void RoutesThroughProxy()
    {
        if (Fh.SkipWithout("proxy")) return;
        var rec = new FhRecorder();
        var f = new ProxyFeature();
        var h = Fh.Make(rec.Fetch,
            (f, new Dictionary<string, object?> { ["url"] = "http://proxy:8080" }));
        h.Op(new FhOpSpec { Op = "load" });
        Assert.Equal("http://proxy:8080", rec.Fetchdef(0)["proxy"]);
        Assert.Equal(1, f.Routed);
    }

    [Fact]
    public void BypassesNoproxyHosts()
    {
        if (Fh.SkipWithout("proxy")) return;
        var rec = new FhRecorder();
        var h = Fh.Make(rec.Fetch, (new ProxyFeature(), new Dictionary<string, object?>
        {
            ["url"] = "http://proxy:8080",
            ["noProxy"] = new List<object?> { "api.test" },
        }));
        h.Op(new FhOpSpec { Op = "load" });
        Assert.False(rec.Fetchdef(0).ContainsKey("proxy"),
            "expected noProxy bypass");
    }

    [Fact]
    public void FromenvReadsHttpsProxy()
    {
        if (Fh.SkipWithout("proxy")) return;
        var prev = Environment.GetEnvironmentVariable("HTTPS_PROXY");
        Environment.SetEnvironmentVariable("HTTPS_PROXY", "http://env-proxy:8080");
        try
        {
            var rec = new FhRecorder();
            var h = Fh.Make(rec.Fetch,
                (new ProxyFeature(), new Dictionary<string, object?> { ["fromEnv"] = true }));
            h.Op(new FhOpSpec { Op = "load" });
            Assert.Equal("http://env-proxy:8080", rec.Fetchdef(0)["proxy"]);
        }
        finally
        {
            Environment.SetEnvironmentVariable("HTTPS_PROXY", prev);
        }
    }

    [Fact]
    public void NoUrlIsNoop()
    {
        if (Fh.SkipWithout("proxy")) return;
        var rec = new FhRecorder();
        var h = Fh.Make(rec.Fetch, (new ProxyFeature(), null));
        h.Op(new FhOpSpec { Op = "load" });
        Assert.False(rec.Fetchdef(0).ContainsKey("proxy"),
            "expected no proxy annotation");
    }

    [Fact]
    public void InactiveDoesNotWrap()
    {
        if (Fh.SkipWithout("proxy")) return;
        var rec = new FhRecorder();
        var h = Fh.Make(rec.Fetch, (new ProxyFeature(), new Dictionary<string, object?>
        {
            ["active"] = false,
            ["url"] = "http://proxy:8080",
        }));
        h.Op(new FhOpSpec { Op = "load" });
        Assert.False(rec.Fetchdef(0).ContainsKey("proxy"),
            "inactive proxy must not route");
    }
}

// --- composition ----------------------------------------------------------------

public class FeatureCompositionTest
{
    [Fact]
    public void CacheHitSkipsSimulatedFailure()
    {
        if (Fh.SkipWithout("cache", "netsim")) return;
        var nf = new NetsimFeature();
        var h = Fh.Make(null,
            (nf, new Dictionary<string, object?> { ["failEvery"] = 2 }),
            (new CacheFeature(), new Dictionary<string, object?> { ["ttl"] = 10000 }));
        var first = h.Op(new FhOpSpec { Op = "load", Path = "/w" });
        Assert.True(first.Ok, $"first load should succeed: {first.Err}");
        var second = h.Op(new FhOpSpec { Op = "load", Path = "/w" });
        Assert.True(second.Ok, $"second load should hit the cache: {second.Err}");
        Assert.Equal(1, nf.Calls);
    }
}
