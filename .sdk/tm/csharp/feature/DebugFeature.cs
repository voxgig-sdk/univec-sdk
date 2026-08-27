// Request/response capture for debugging. Records a bounded ring buffer of
// per-operation traces - method, URL, redacted headers, response status and
// timing - on the feature's Entries. Sensitive header values (matching
// `redact`, default authorization/cookie/api-key style names) are masked.
// An optional `onEntry` callback receives each finished entry (e.g. to
// stream to a console). `max` caps the buffer (default 100).

using static UnivecSdk.Feature.FeatureOptions;

namespace UnivecSdk.Feature;

public class DebugFeature : BaseFeature
{
    private UnivecSDK? _client;
    private Dictionary<string, object?>? _options;

    // Activity tracking (mirrors the ts client._debug record).
    public List<Dictionary<string, object?>> Entries = new();

    private const string EntryKey = "debug_entry";

    private static readonly List<string> DefaultRedact = new()
    {
        "authorization", "cookie", "set-cookie", "api-key", "apikey",
        "x-api-key", "idempotency-key",
    };

    public DebugFeature()
    {
        Version = "0.0.1";
        Name = "debug";
        Active = true;
    }

    public override void Init(Context ctx, Dictionary<string, object?> options)
    {
        _client = ctx.Client;
        _options = options;
        Active = FoptBool(options, "active", false);
    }

    public override void PreRequest(Context ctx)
    {
        if (!Active)
        {
            return;
        }

        var entity = ctx.Op?.Entity ?? "_";
        var opname = ctx.Op?.Name ?? "_";

        var entry = new Dictionary<string, object?>
        {
            ["op"] = entity + "." + opname,
            ["start"] = FoptNow(_options)(),
        };
        if (ctx.Spec != null)
        {
            entry["method"] = ctx.Spec.Method;
            entry["url"] = ctx.Spec.Url != "" ? ctx.Spec.Url : ctx.Spec.Path;
            entry["headers"] = Redact(ctx.Spec.Headers);
        }
        ctx.Out[EntryKey] = entry;
    }

    public override void PreResponse(Context ctx)
    {
        if (!Active)
        {
            return;
        }

        var entry = ctx.Out.TryGetValue(EntryKey, out var raw)
            ? raw as Dictionary<string, object?> : null;
        if (entry == null)
        {
            return;
        }
        if (ctx.Response != null)
        {
            entry["status"] = ctx.Response.Status;
            if ((entry.TryGetValue("url", out var u) ? u as string : "") == "" && ctx.Spec != null)
            {
                entry["url"] = ctx.Spec.Url;
            }
        }
    }

    public override void PreDone(Context ctx)
    {
        Finish(ctx, true);
    }

    public override void PreUnexpected(Context ctx)
    {
        if (ctx.Out.TryGetValue(EntryKey, out var raw) &&
            raw is Dictionary<string, object?> entry &&
            ctx.Ctrl?.Err != null)
        {
            entry["error"] = ctx.Ctrl.Err.Message;
        }
        Finish(ctx, false);
    }

    private void Finish(Context ctx, bool ok)
    {
        // Finish once per operation: the marker in ctx.Out is consumed here.
        var entry = ctx.Out.TryGetValue(EntryKey, out var raw)
            ? raw as Dictionary<string, object?> : null;
        if (entry == null)
        {
            return;
        }
        ctx.Out.Remove(EntryKey);

        entry["ok"] = ok && (ctx.Result == null || ctx.Result.Ok);
        var start = entry.TryGetValue("start", out var sraw) ? Helpers.ToLong(sraw) : 0;
        var dur = FoptNow(_options)() - start;
        if (dur < 0)
        {
            dur = 0;
        }
        entry["durationMs"] = dur;
        if ((!entry.TryGetValue("status", out var st) || st == null) && ctx.Result != null)
        {
            entry["status"] = ctx.Result.Status;
        }

        Entries.Add(entry);
        var max = FoptInt(_options, "max", 100);
        while (Entries.Count > max)
        {
            Entries.RemoveAt(0);
        }

        if (Opt(_options, "onEntry") is Action<Dictionary<string, object?>> onEntry)
        {
            onEntry(entry);
        }
    }

    private Dictionary<string, object?> Redact(Dictionary<string, object?>? headers)
    {
        var redacted = new Dictionary<string, object?>();
        if (headers == null)
        {
            return redacted;
        }
        var patterns = FoptStrList(_options, "redact") ?? DefaultRedact;
        foreach (var kv in headers)
        {
            var masked = patterns.Any(p => kv.Key.ToLowerInvariant() == p);
            redacted[kv.Key] = masked ? "<redacted>" : kv.Value;
        }
        return redacted;
    }
}
