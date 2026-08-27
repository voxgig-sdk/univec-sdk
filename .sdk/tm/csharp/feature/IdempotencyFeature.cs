// Idempotency keys for mutating operations. Adds an `Idempotency-Key`
// header (name configurable via `header`) to unsafe requests so a server
// can de-duplicate retried writes. The key is set once, at PreRequest,
// before the request is built - so it is stable across transport-level
// retries of the same call. A caller-supplied header is never overwritten
// (case-insensitive). The key generator is injectable (`keygen`).

using static UnivecSdk.Feature.FeatureOptions;

namespace UnivecSdk.Feature;

public class IdempotencyFeature : BaseFeature
{
    private UnivecSDK? _client;
    private Dictionary<string, object?>? _options;

    // Activity tracking (mirrors the ts client._idempotency record).
    public int Issued;
    public string Last = "";

    public IdempotencyFeature()
    {
        Version = "0.0.1";
        Name = "idempotency";
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

        var spec = ctx.Spec;
        if (spec == null)
        {
            return;
        }

        if (!Mutating(ctx))
        {
            return;
        }

        var header = FoptStr(_options, "header", "Idempotency-Key");
        spec.Headers ??= new Dictionary<string, object?>();

        // Respect a key the caller already provided.
        var (_, has) = FheaderGet(spec.Headers, header);
        if (has)
        {
            return;
        }

        var key = Genkey();
        spec.Headers[header] = key;

        Issued++;
        Last = key;
    }

    private bool Mutating(Context ctx)
    {
        var methods = FoptStrList(_options, "methods")
            ?? new List<string> { "POST", "PUT", "PATCH", "DELETE" };
        var method = ctx.Spec?.Method.ToUpperInvariant() ?? "";
        if (method != "" && methods.Any(m => m.ToUpperInvariant() == method))
        {
            return true;
        }

        var opname = ctx.Op?.Name ?? "";
        var ops = FoptStrList(_options, "ops")
            ?? new List<string> { "create", "update", "remove" };
        return ops.Contains(opname);
    }

    private string Genkey()
    {
        if (Opt(_options, "keygen") is Func<string> keygen)
        {
            return keygen();
        }
        var key = string.Format("{0:x6}{1:x6}{2:x6}{3:x6}",
            Random.Shared.Next(0x1000000), Random.Shared.Next(0x1000000),
            Random.Shared.Next(0x1000000), Random.Shared.Next(0x1000000));
        return key[..24];
    }
}
