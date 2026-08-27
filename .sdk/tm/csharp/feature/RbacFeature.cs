// Client-side role/permission enforcement. Before an operation resolves its
// endpoint, the required permission for that entity+operation is checked
// against the permissions the client holds; a disallowed call is
// short-circuited with an `rbac_denied` error (via ctx.Out["point"], which
// MakePoint surfaces) and never touches the network. Required permissions
// come from `rules` (keyed by `<entity>.<op>`, `<op>`, or `*`); the default
// when no rule matches is controlled by `deny` (default: allow when
// unspecified). Held permissions are the `permissions` list (a `*` grants
// everything).

using static UnivecSdk.Feature.FeatureOptions;

namespace UnivecSdk.Feature;

public class RbacFeature : BaseFeature
{
    private UnivecSDK? _client;
    private Dictionary<string, object?>? _options;
    private HashSet<string> _granted = new();

    // Activity tracking (mirrors the ts client._rbac record).
    public int Allowed;
    public int Denied;
    public Dictionary<string, object?>? Last;

    public RbacFeature()
    {
        Version = "0.0.1";
        Name = "rbac";
        Active = true;
    }

    public override void Init(Context ctx, Dictionary<string, object?> options)
    {
        _client = ctx.Client;
        _options = options;
        Active = FoptBool(options, "active", false);

        _granted = new HashSet<string>();
        foreach (var p in FoptStrList(_options, "permissions") ?? new List<string>())
        {
            _granted.Add(p);
        }
    }

    public override void PrePoint(Context ctx)
    {
        if (!Active)
        {
            return;
        }

        var (required, has) = Required(ctx);
        if (!has)
        {
            // No rule: honour the default policy.
            if (FoptBool(_options, "deny", false))
            {
                Reject(ctx, "<default-deny>");
            }
            return;
        }

        if (_granted.Contains("*") || _granted.Contains(required))
        {
            Track(ctx, required, true);
            return;
        }

        Reject(ctx, required);
    }

    private (string, bool) Required(Context ctx)
    {
        var rules = FoptMap(_options, "rules");
        if (rules == null)
        {
            return ("", false);
        }

        var entity = ctx.Entity?.GetName() ?? ctx.Op?.Entity ?? "";
        var opname = ctx.Op?.Name ?? "";

        foreach (var key in new[] { entity + "." + opname, opname, "*" })
        {
            if (rules.TryGetValue(key, out var r) && r is string rs)
            {
                return (rs, true);
            }
        }
        return ("", false);
    }

    private void Reject(Context ctx, string required)
    {
        Track(ctx, required, false);

        var opname = ctx.Op?.Name ?? "?";
        var err = ctx.MakeError("rbac_denied",
            "Permission \"" + required + "\" required for operation \"" + opname + "\"");

        // Short-circuit endpoint resolution; MakePoint surfaces this error
        // before any network activity.
        ctx.Out["point"] = err;
    }

    private void Track(Context ctx, string required, bool allowed)
    {
        if (allowed)
        {
            Allowed++;
        }
        else
        {
            Denied++;
        }
        Last = new Dictionary<string, object?>
        {
            ["required"] = required,
            ["allowed"] = allowed,
            ["op"] = ctx.Op?.Name ?? "",
        };
    }
}
