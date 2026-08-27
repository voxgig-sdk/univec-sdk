// Response caching for safe (read) requests. Wraps the active transport and
// serves a fresh cached snapshot instead of hitting the network when the
// same method+URL was fetched within `ttl` ms (default: 5000). Only
// successful (2xx) responses to cacheable methods (default: GET) are
// stored, keyed by method+URL. The cache is bounded (`max` entries, default
// 256, oldest evicted first) and every hit/miss/bypass is counted. Bodies
// are snapshotted on capture so both the current caller and later hits can
// re-read the JSON body repeatedly.

using static UnivecSdk.Feature.FeatureOptions;

namespace UnivecSdk.Feature;

public class CacheFeature : BaseFeature
{
    private UnivecSDK? _client;
    private Dictionary<string, object?>? _options;
    private Dictionary<string, CacheEntry> _store = new();
    private List<string> _order = new();

    // Activity tracking (mirrors the ts client._cache record).
    public int Hit;
    public int Miss;
    public int Bypass;

    private class CacheEntry
    {
        public long Expiry;
        public CacheSnapshot Snapshot = new();
    }

    private class CacheSnapshot
    {
        public int Status;
        public string StatusText = "";
        public object? Data;
        public Dictionary<string, object?> Headers = new();
    }

    public CacheFeature()
    {
        Version = "0.0.1";
        Name = "cache";
        Active = true;
    }

    public override void Init(Context ctx, Dictionary<string, object?> options)
    {
        _client = ctx.Client;
        _options = options;
        Active = FoptBool(options, "active", false);

        if (!Active)
        {
            return;
        }

        _store = new Dictionary<string, CacheEntry>();
        _order = new List<string>();

        var inner = ctx.Utility!.Fetcher;

        ctx.Utility.Fetcher = (ctx2, url, fetchdef) => Through(ctx2, url, fetchdef, inner);
    }

    private object? Through(Context ctx, string url, Dictionary<string, object?> fetchdef,
        FetcherFunc inner)
    {
        var method = "GET";
        if (fetchdef.TryGetValue("method", out var mraw) && mraw is string m && m != "")
        {
            method = m.ToUpperInvariant();
        }

        var methods = FoptStrList(_options, "methods") ?? new List<string> { "GET" };
        var cacheable = methods.Any(x => x.ToUpperInvariant() == method);
        if (!cacheable)
        {
            return inner(ctx, url, fetchdef);
        }

        var key = method + " " + url;
        var now = FoptNow(_options)();

        if (_store.TryGetValue(key, out var hit) && hit.Expiry > now)
        {
            Hit++;
            return Replay(hit.Snapshot);
        }

        object? res = null;
        Exception? err = null;
        try
        {
            res = inner(ctx, url, fetchdef);
        }
        catch (Exception ex)
        {
            err = ex;
        }

        if (err == null && Storable(res))
        {
            var snapshot = Snapshot(res);
            var ttl = FoptInt(_options, "ttl", 5000);
            Evict();
            _store[key] = new CacheEntry { Expiry = now + ttl, Snapshot = snapshot };
            _order.Add(key);
            Miss++;
            return Replay(snapshot);
        }

        Bypass++;
        if (err != null)
        {
            throw err;
        }
        return res;
    }

    private static bool Storable(object? res)
    {
        var (status, has) = FresStatus(res);
        return has && status >= 200 && status < 300;
    }

    private static CacheSnapshot Snapshot(object? res)
    {
        var rm = res as Dictionary<string, object?>;
        var snap = new CacheSnapshot();

        var (status, has) = FresStatus(res);
        if (has)
        {
            snap.Status = status;
        }
        if (rm != null)
        {
            if (rm.TryGetValue("statusText", out var st) && st is string sts)
            {
                snap.StatusText = sts;
            }
            if (rm.TryGetValue("json", out var jf) && jf is Func<object?> f)
            {
                snap.Data = f();
            }
            if (rm.TryGetValue("headers", out var hraw) && hraw is Dictionary<string, object?> headers)
            {
                foreach (var kv in headers)
                {
                    snap.Headers[kv.Key.ToLowerInvariant()] = kv.Value;
                }
            }
        }

        return snap;
    }

    // Replay builds a fresh transport-shaped response so the body stays
    // re-readable for every consumer.
    private static Dictionary<string, object?> Replay(CacheSnapshot snap)
    {
        var data = snap.Data;
        var headers = new Dictionary<string, object?>(snap.Headers);
        return new Dictionary<string, object?>
        {
            ["status"] = snap.Status,
            ["statusText"] = snap.StatusText,
            ["body"] = "not-used",
            ["json"] = (Func<object?>)(() => data),
            ["headers"] = headers,
        };
    }

    // Evict drops oldest entries (FIFO) until the store is under `max`.
    private void Evict()
    {
        var max = FoptInt(_options, "max", 256);
        while (_store.Count >= max && _order.Count > 0)
        {
            var oldest = _order[0];
            _order.RemoveAt(0);
            _store.Remove(oldest);
        }
    }
}
