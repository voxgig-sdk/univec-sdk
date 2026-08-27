// Automatic retry of transient failures with exponential backoff and
// jitter. Wraps the active transport so a single operation call may make
// several HTTP attempts. A failure is retryable when the transport throws,
// returns null, or responds with a status in `statuses`
// (default: 408, 425, 429, 500, 502, 503, 504). An HTTP 429/503 with a
// `Retry-After` header overrides the computed backoff.

using static UnivecSdk.Feature.FeatureOptions;

namespace UnivecSdk.Feature;

public class RetryFeature : BaseFeature
{
    private UnivecSDK? _client;
    private Dictionary<string, object?>? _options;

    // Activity tracking (mirrors the ts client._retry record).
    public int Attempts;
    public List<Dictionary<string, object?>> Retries = new();

    public RetryFeature()
    {
        Version = "0.0.1";
        Name = "retry";
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

        var inner = ctx.Utility!.Fetcher;

        ctx.Utility.Fetcher = (ctx2, url, fetchdef) => WithRetry(ctx2, url, fetchdef, inner);
    }

    private object? WithRetry(Context ctx, string url, Dictionary<string, object?> fetchdef,
        FetcherFunc inner)
    {
        var max = FoptInt(_options, "retries", 2);
        var minDelay = FoptInt(_options, "minDelay", 50);
        var maxDelay = FoptInt(_options, "maxDelay", 2000);
        var factor = FoptNum(_options, "factor", 2);

        var attempt = 0;

        while (true)
        {
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

            if (!Retryable(res, err) || attempt >= max)
            {
                // Out of attempts (or not retryable): return the last
                // response as-is (or rethrow) to preserve pipeline semantics.
                if (err != null)
                {
                    throw err;
                }
                return res;
            }

            var wait = Backoff(res, attempt, minDelay, maxDelay, factor);
            Track(attempt + 1, res, err, wait);
            SleepMs(wait);
            attempt++;
        }
    }

    private bool Retryable(object? res, Exception? err)
    {
        if (err != null)
        {
            return true;
        }
        if (res == null)
        {
            return true;
        }
        var (status, has) = FresStatus(res);
        if (!has)
        {
            return false;
        }
        var statuses = FoptList(_options, "statuses")
            ?? new List<object?> { 408, 425, 429, 500, 502, 503, 504 };
        foreach (var s in statuses)
        {
            if (Helpers.ToInt(s) == status)
            {
                return true;
            }
        }
        return false;
    }

    private int Backoff(object? res, int attempt, int minDelay, int maxDelay, double factor)
    {
        // Honour a server-provided Retry-After (seconds) when present.
        var (ra, has) = RetryAfter(res);
        if (has)
        {
            return ra > maxDelay ? maxDelay : ra;
        }
        var baseWait = minDelay * Math.Pow(factor, attempt);
        var jitter = 0;
        if (FoptBool(_options, "jitter", true) && minDelay > 0)
        {
            jitter = Random.Shared.Next(minDelay);
        }
        var wait = (int)baseWait + jitter;
        return wait > maxDelay ? maxDelay : wait;
    }

    private (int, bool) RetryAfter(object? res)
    {
        var (v, has) = FresHeader(res, "retry-after");
        if (!has)
        {
            return (0, false);
        }
        var seconds = FparseInt(v, -1);
        if (seconds < 0)
        {
            return (0, false);
        }
        return (seconds * 1000, true);
    }

    private void SleepMs(int ms)
    {
        if (ms <= 0)
        {
            return;
        }
        FoptSleep(_options)(ms);
    }

    private void Track(int attempt, object? res, Exception? err, int wait)
    {
        Attempts++;

        var entry = new Dictionary<string, object?>
        {
            ["attempt"] = attempt,
            ["wait"] = wait,
        };
        var (status, has) = FresStatus(res);
        if (has)
        {
            entry["status"] = status;
        }
        if (err != null)
        {
            entry["error"] = err.Message;
        }
        Retries.Add(entry);
    }
}
