// Client-side rate limiting via a token bucket. Each request consumes a
// token; when the bucket is empty the request waits until the bucket
// refills at `rate` tokens per second (with capacity `burst`, default:
// rate). This keeps the client under a server's published quota rather
// than discovering it via 429s. The clock (`now`) and the wait (`sleep`)
// are injectable so the accounting can be tested deterministically.

using static UnivecSdk.Feature.FeatureOptions;

namespace UnivecSdk.Feature;

public class RatelimitFeature : BaseFeature
{
    private UnivecSDK? _client;
    private Dictionary<string, object?>? _options;
    private double _tokens;
    private long _last;

    // Activity tracking (mirrors the ts client._ratelimit record).
    public int Throttled;
    public int WaitMs;

    public RatelimitFeature()
    {
        Version = "0.0.1";
        Name = "ratelimit";
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

        var rate = FoptNum(_options, "rate", 5);
        var burst = FoptNum(_options, "burst", rate);
        _tokens = burst;
        _last = FoptNow(_options)();

        var inner = ctx.Utility!.Fetcher;

        ctx.Utility.Fetcher = (ctx2, url, fetchdef) =>
        {
            Acquire();
            return inner(ctx2, url, fetchdef);
        };
    }

    private void Acquire()
    {
        var rate = FoptNum(_options, "rate", 5);
        var burst = FoptNum(_options, "burst", rate);

        // Refill according to elapsed time.
        var now = FoptNow(_options)();
        var elapsed = now - _last;
        _last = now;
        _tokens = Math.Min(burst, _tokens + (elapsed / 1000.0) * rate);

        if (_tokens >= 1)
        {
            _tokens -= 1;
            return;
        }

        // Not enough tokens: wait for one to accrue, then consume it.
        var needed = 1 - _tokens;
        var waitMs = (int)Math.Ceiling((needed / rate) * 1000);
        Track(waitMs);
        if (waitMs > 0)
        {
            FoptSleep(_options)(waitMs);
        }
        _last = FoptNow(_options)();
        _tokens = 0;
    }

    private void Track(int waitMs)
    {
        Throttled++;
        WaitMs += waitMs;
    }
}
