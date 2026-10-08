// Per-request timeout. Wraps the active transport and races each attempt
// against a Task.Delay deadline; if the deadline wins, the request resolves
// to a `timeout` error instead of hanging. The inner transport is left to
// finish on its own task (its result is discarded), matching how the ts
// feature lets the losing racer resolve unobserved.

using static UnivecSdk.Feature.FeatureOptions;

namespace UnivecSdk.Feature;

public class TimeoutFeature : BaseFeature
{
    private UnivecSDK? _client;
    private Dictionary<string, object?>? _options;

    // Activity tracking (mirrors the ts client._timeout record).
    public int Count;
    public int Ms;

    public TimeoutFeature()
    {
        Version = "0.0.1";
        Name = "timeout";
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

        ctx.Utility.Fetcher = (ctx2, url, fetchdef) => WithTimeout(ctx2, url, fetchdef, inner);
    }

    private object? WithTimeout(Context ctx, string url, Dictionary<string, object?> fetchdef,
        FetcherFunc inner)
    {
        var ms = FoptInt(_options, "ms", 30000);
        if (ms <= 0)
        {
            return inner(ctx, url, fetchdef);
        }

        // The deadline runs from here, not from the wait below: a caller paused
        // between the two would otherwise find a late response complete and
        // take it. The worker notes when it finished, so a response or a
        // failure after the deadline is a timeout however late the caller looks.
        var now = FoptNow(_options);
        var start = now();
        long arrived = long.MaxValue;
        var task = Task.Run(() =>
        {
            try
            {
                return inner(ctx, url, fetchdef);
            }
            finally
            {
                Interlocked.Exchange(ref arrived, now());
            }
        });

        var remaining = Math.Max(0L, ms - (now() - start));
        if (task == Task.WhenAny(task, Task.Delay(TimeSpan.FromMilliseconds(remaining)))
            .GetAwaiter().GetResult())
        {
            if (ms < Interlocked.Read(ref arrived) - start)
            {
                throw TimedOut(ctx, ms);
            }
            // Unwraps any inner exception.
            return task.GetAwaiter().GetResult();
        }

        throw TimedOut(ctx, ms);
    }

    private Exception TimedOut(Context ctx, int ms)
    {
        Track(ms);
        return ctx.MakeError("timeout", $"Request exceeded timeout of {ms}ms");
    }

    private void Track(int ms)
    {
        Count++;
        Ms = ms;
    }
}
