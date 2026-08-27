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

        var task = Task.Run(() => inner(ctx, url, fetchdef));

        if (task == Task.WhenAny(task, Task.Delay(ms)).GetAwaiter().GetResult())
        {
            // Unwraps any inner exception.
            return task.GetAwaiter().GetResult();
        }

        Track(ms);
        throw ctx.MakeError("timeout", $"Request exceeded timeout of {ms}ms");
    }

    private void Track(int ms)
    {
        Count++;
        Ms = ms;
    }
}
