// Streaming result support. For list-style operations it attaches a
// `Result.Stream` function yielding an IEnumerable so callers can consume
// items incrementally with `foreach (var item in result.Stream!())` instead
// of materialising the whole list at once. A `chunkSize` groups items into
// List<object?> batches when set; a `chunkDelay` (ms) paces delivery via the
// injectable `sleep` for offline tests. The enumerable is pull-based, so
// abandoning a stream never leaks a producer.

using static UnivecSdk.Feature.FeatureOptions;

namespace UnivecSdk.Feature;

public class StreamingFeature : BaseFeature
{
    private UnivecSDK? _client;
    private Dictionary<string, object?>? _options;

    // Activity tracking (mirrors the ts client._streaming record).
    public int Opened;

    public StreamingFeature()
    {
        Version = "0.0.1";
        Name = "streaming";
        Active = true;
    }

    public override void Init(Context ctx, Dictionary<string, object?> options)
    {
        _client = ctx.Client;
        _options = options;
        Active = FoptBool(options, "active", false);
    }

    public override void PreResult(Context ctx)
    {
        if (!Active || !Streamable(ctx))
        {
            return;
        }
        var result = ctx.Result;
        if (result == null)
        {
            return;
        }

        result.Streaming = true;
        result.Stream = () => Iterate(result);

        Opened++;
    }

    private IEnumerable<object?> Iterate(Result result)
    {
        var chunkDelay = FoptInt(_options, "chunkDelay", 0);
        var chunkSize = FoptInt(_options, "chunkSize", 0);
        var sleep = FoptSleep(_options);

        // Read lazily at Stream() call time so downstream result processing
        // is reflected.
        var items = result.Resdata as List<object?> ?? new List<object?>();

        if (chunkSize > 0)
        {
            for (var i = 0; i < items.Count; i += chunkSize)
            {
                if (chunkDelay > 0)
                {
                    sleep(chunkDelay);
                }
                var end = Math.Min(i + chunkSize, items.Count);
                yield return items.GetRange(i, end - i);
            }
            yield break;
        }

        foreach (var item in items)
        {
            if (chunkDelay > 0)
            {
                sleep(chunkDelay);
            }
            yield return item;
        }
    }

    private bool Streamable(Context ctx)
    {
        var opname = ctx.Op?.Name ?? "";
        var ops = FoptStrList(_options, "ops") ?? new List<string> { "list" };
        return ops.Contains(opname);
    }
}
