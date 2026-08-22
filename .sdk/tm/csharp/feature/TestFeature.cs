// In-memory mock transport for testing without a live server. Serves the
// per-entity fixture data supplied via the test feature options (`entity`)
// and answers CRUD requests the way a REST server would. An optional `net`
// block layers deterministic network-behaviour simulation (latency,
// first-N failures, connection errors, offline) over the mock.

using Voxgig.Struct;

using static UnivecSdk.Feature.FeatureOptions;

namespace UnivecSdk.Feature;

public class TestFeature : BaseFeature
{
    private UnivecSDK? _client;
    private Dictionary<string, object?>? _options;
    private int _netcalls;

    public TestFeature()
    {
        Version = "0.0.1";
        Name = "test";
        Active = true;
    }

    public override void Init(Context ctx, Dictionary<string, object?> options)
    {
        _client = ctx.Client;
        _options = options;

        var entity = Helpers.ToMapAny(StructUtils.GetProp(options, "entity"))
            ?? new Dictionary<string, object?>();

        _client!.Mode = "test";

        // Ensure entity ids are correct.
        StructUtils.Walk(entity, (key, val, parent, path) =>
        {
            if (path.Count == 2 && val is Dictionary<string, object?> m && key != null)
            {
                m["id"] = StructUtils.StrKey(key);
            }
            return val;
        });

        FetcherFunc testFetcher = (ctx2, _fullurl, _fetchdef) =>
        {
            static Dictionary<string, object?> Respond(int status, object? data,
                Dictionary<string, object?>? extra)
            {
                var res = new Dictionary<string, object?>
                {
                    ["status"] = status,
                    ["statusText"] = "OK",
                    ["json"] = (Func<object?>)(() => data),
                    ["body"] = "not-used",
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

            var op = ctx2.Op!;
            var entmap = Helpers.ToMapAny(StructUtils.GetProp(entity, op.Entity))
                ?? new Dictionary<string, object?>();

            // For single-entity ops (load, remove) with an empty explicit
            // match, fall back to the id the entity client already knows from
            // a prior create/load (in ctx.Match / ctx.Data). Mirrors the TS
            // mock where param() resolves the id from that accumulated state.
            Dictionary<string, object?> ResolveMatch(Dictionary<string, object?> explicitMatch)
            {
                if (explicitMatch.Count > 0)
                {
                    return explicitMatch;
                }
                foreach (var src in new object?[] { ctx2.Match, ctx2.Data })
                {
                    if (src == null)
                    {
                        continue;
                    }
                    var v = StructUtils.GetProp(src, "id");
                    if (v != null && !Equals(v, "__UNDEFINED__"))
                    {
                        return new Dictionary<string, object?> { ["id"] = v };
                    }
                }
                return new Dictionary<string, object?>();
            }

            if (op.Name == "load")
            {
                var args = BuildArgs(ctx2, op, ResolveMatch(ctx2.Reqmatch));
                var found = StructUtils.Select(entmap, args);
                var ent = StructUtils.GetElem(found, 0);
                if (ent == null)
                {
                    return Respond(404, null, new Dictionary<string, object?>
                    {
                        ["statusText"] = "Not found",
                    });
                }
                StructUtils.DelProp(ent, "$KEY");
                var outval = StructUtils.Clone(ent);
                return Respond(200, outval, null);
            }
            else if (op.Name == "list")
            {
                var args = BuildArgs(ctx2, op, ctx2.Reqmatch);
                var found = StructUtils.Select(entmap, args);
                if (found == null)
                {
                    return Respond(404, null, new Dictionary<string, object?>
                    {
                        ["statusText"] = "Not found",
                    });
                }
                foreach (var item in found)
                {
                    StructUtils.DelProp(item, "$KEY");
                }
                var outval = StructUtils.Clone(found);
                return Respond(200, outval, null);
            }
            else if (op.Name == "update")
            {
                // Match the existing entity by id only (or its alias).
                // Reqdata also contains the new field values, which would
                // otherwise cause Select to filter out the entity we want to
                // update. When reqdata has no id, fall back to the id the
                // entity client carries from a prior create/load.
                var updateMatch = new Dictionary<string, object?>();
                if (ctx2.Reqdata != null)
                {
                    if (ctx2.Reqdata.TryGetValue("id", out var idv))
                    {
                        updateMatch["id"] = idv;
                    }
                    if (op.Alias != null &&
                        StructUtils.GetProp(op.Alias, "id") is string aliasId &&
                        ctx2.Reqdata.TryGetValue(aliasId, out var av))
                    {
                        updateMatch[aliasId] = av;
                    }
                }
                if (updateMatch.Count == 0)
                {
                    updateMatch = ResolveMatch(new Dictionary<string, object?>());
                }
                var args = BuildArgs(ctx2, op, updateMatch);
                var found = StructUtils.Select(entmap, args);
                var ent = StructUtils.GetElem(found, 0);
                if (ent == null && entmap != null)
                {
                    foreach (var e in entmap.Values)
                    {
                        if (e is Dictionary<string, object?>)
                        {
                            ent = e;
                            break;
                        }
                    }
                }
                if (ent == null)
                {
                    return Respond(404, null, new Dictionary<string, object?>
                    {
                        ["statusText"] = "Not found",
                    });
                }
                if (ent is Dictionary<string, object?> entm && ctx2.Reqdata != null)
                {
                    foreach (var kv in ctx2.Reqdata)
                    {
                        entm[kv.Key] = kv.Value;
                    }
                }
                StructUtils.DelProp(ent, "$KEY");
                var outval = StructUtils.Clone(ent);
                return Respond(200, outval, null);
            }
            else if (op.Name == "remove")
            {
                var args = BuildArgs(ctx2, op, ResolveMatch(ctx2.Reqmatch));
                var found = StructUtils.Select(entmap, args);
                var ent = StructUtils.GetElem(found, 0);
                // Remove only the first matched entity. If nothing matches,
                // succeed as a no-op rather than erroring.
                if (ent is Dictionary<string, object?> entm2)
                {
                    var id = StructUtils.GetProp(entm2, "id");
                    StructUtils.DelProp(entmap, id);
                }
                return Respond(200, null, null);
            }
            else if (op.Name == "create")
            {
                _ = BuildArgs(ctx2, op, ctx2.Reqdata);
                var id = ctx2.Utility!.Param(ctx2, "id");
                id ??= string.Format("{0:x4}{1:x4}{2:x4}{3:x4}",
                    Random.Shared.Next(0x10000), Random.Shared.Next(0x10000),
                    Random.Shared.Next(0x10000), Random.Shared.Next(0x10000));

                var ent = StructUtils.Clone(ctx2.Reqdata);
                if (ent is Dictionary<string, object?> entm)
                {
                    entm["id"] = id;
                    if (id is string idStr)
                    {
                        entmap![idStr] = entm;
                    }
                    StructUtils.DelProp(entm, "$KEY");
                    var outval = StructUtils.Clone(entm);
                    return Respond(200, outval, null);
                }
                return Respond(200, ent, null);
            }

            return Respond(404, null, new Dictionary<string, object?>
            {
                ["statusText"] = "Unknown operation",
            });
        };

        // Optional network behaviour simulation over the mock transport.
        // Enable per test via `TestSDK(new(){["net"]=...}, null)`. When `net`
        // is absent the mock behaves exactly as before (no wrapping), so
        // existing generated tests are unaffected.
        var net = Helpers.ToMapAny(StructUtils.GetProp(options, "net"));
        ctx.Utility!.Fetcher = net == null ? testFetcher : MakeNetsim(net, testFetcher);
    }

    // MakeNetsim wraps a transport with simulated network conditions: latency
    // (fixed or {min,max}), a budget of first-N failures (`failTimes` ->
    // `failStatus`), first-N connection errors (`errorTimes`), or a hard
    // `offline` outage. Counter-driven, so simulations are deterministic
    // across a test.
    private FetcherFunc MakeNetsim(Dictionary<string, object?> net, FetcherFunc inner)
    {
        _netcalls = 0;

        int PickLatency()
        {
            if (!net.TryGetValue("latency", out var l) || l == null)
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
                return min + ((max - min) >> 1);
            }
            var fixedMs = FoptInt(net, "latency", 0);
            return fixedMs < 0 ? 0 : fixedMs;
        }

        void SleepMs(int ms)
        {
            if (ms <= 0)
            {
                return;
            }
            FoptSleep(net)(ms);
        }

        return (ctx, url, fetchdef) =>
        {
            _netcalls++;
            var call = _netcalls;

            if (net.TryGetValue("offline", out var off) && off is bool netOffline && netOffline)
            {
                SleepMs(PickLatency());
                throw ctx.MakeError("netsim_offline",
                    "Simulated network offline (URL was: \"" + url + "\")");
            }
            if (call <= FoptInt(net, "errorTimes", 0))
            {
                SleepMs(PickLatency());
                throw ctx.MakeError("netsim_conn",
                    $"Simulated connection error (call {call})");
            }
            if (call <= FoptInt(net, "failTimes", 0))
            {
                SleepMs(PickLatency());
                var status = FoptInt(net, "failStatus", 503);
                return new Dictionary<string, object?>
                {
                    ["status"] = status,
                    ["statusText"] = "Simulated Failure",
                    ["body"] = "not-used",
                    ["json"] = (Func<object?>)(() => null),
                    ["headers"] = new Dictionary<string, object?>(),
                };
            }
            SleepMs(PickLatency());
            return inner(ctx, url, fetchdef);
        };
    }

    private static object BuildArgs(Context ctx, Operation op, Dictionary<string, object?>? args)
    {
        var opname = op.Name;

        // Pick the entity's own endpoint from config, not a cross-reference
        // from another resource that also returns it — the same rule
        // MakePoint falls back to, so the seed-data query is built from the
        // endpoint the request will actually be sent to: a terminal `{id}`
        // marks a record route, and failing that the shallower path wins.
        var points = StructUtils.GetPath(ctx.Config,
            StructUtils.Jt("entity", ctx.Entity!.GetName(), "op", opname, "points"));
        var point = StructUtils.GetElem(points, 0);
        if (points is List<object?> pointList)
        {
            static int PointPartsLen(object? p) =>
                StructUtils.GetProp(p, "parts") is List<object?> parts ? parts.Count : 0;
            static bool PointTerminalParam(object? p)
            {
                if (StructUtils.GetProp(p, "parts") is not List<object?> parts || parts.Count == 0)
                {
                    return false;
                }
                return parts[parts.Count - 1] is string last && last.StartsWith("{");
            }

            foreach (var candidate in pointList)
            {
                var candTerm = PointTerminalParam(candidate);
                var bestTerm = PointTerminalParam(point);
                if (candTerm != bestTerm)
                {
                    if (candTerm)
                    {
                        point = candidate;
                    }
                }
                else if (PointPartsLen(candidate) < PointPartsLen(point))
                {
                    point = candidate;
                }
            }
        }

        // Get required params.
        var paramsPath = StructUtils.GetPath(point, StructUtils.Jt("args", "params"));
        var reqdParams = StructUtils.Select(paramsPath,
            new Dictionary<string, object?> { ["reqd"] = true });
        var reqd = StructUtils.Transform(reqdParams,
            StructUtils.Jt("`$EACH`", "", "`$KEY.name`"));

        var qand = new List<object?>();
        var q = new Dictionary<string, object?> { ["`$AND`"] = qand };

        if (args != null)
        {
            foreach (var key in StructUtils.KeysOf(args))
            {
                var isId = key == "id";
                var selected = StructUtils.Select(reqd, key);
                var isReqd = !StructUtils.IsEmpty(selected);

                if (isId || isReqd)
                {
                    var v = ctx.Utility!.Param(ctx, key);
                    var ka = StructUtils.GetProp(op.Alias, key);

                    var qor = new List<object?>
                    {
                        new Dictionary<string, object?> { [key] = v },
                    };
                    if (ka is string kas)
                    {
                        qor.Add(new Dictionary<string, object?> { [kas] = v });
                    }

                    qand.Add(new Dictionary<string, object?> { ["`$OR`"] = qor });
                }
            }
        }

        if (ctx.Ctrl?.Explain != null)
        {
            ctx.Ctrl.Explain["test"] = new Dictionary<string, object?>
            {
                ["query"] = q,
            };
        }

        return q;
    }
}
