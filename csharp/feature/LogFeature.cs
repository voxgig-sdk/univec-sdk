// Structured hook logging. When active, every pipeline hook is written to
// the configured logger: an injected `logger` delegate
// (Action<string level, string msg, Dictionary<string, object?> attrs>) or,
// by default, a simple stderr text logger honouring `level`
// (debug|info|warn|error; default info).

using static UnivecSdk.Feature.FeatureOptions;

namespace UnivecSdk.Feature;

public class LogFeature : BaseFeature
{
    private UnivecSDK? _client;
    private Dictionary<string, object?>? _options;
    private Action<string, string, Dictionary<string, object?>>? _logger;

    public LogFeature()
    {
        Version = "0.0.1";
        Name = "log";
        Active = true;
    }

    private static readonly Dictionary<string, int> Levels = new()
    {
        ["debug"] = 0,
        ["info"] = 1,
        ["warn"] = 2,
        ["error"] = 3,
    };

    public override void Init(Context ctx, Dictionary<string, object?> options)
    {
        _client = ctx.Client;
        _options = options;

        if (Opt(options, "active") is bool active)
        {
            Active = active;
        }

        if (Active)
        {
            if (Opt(options, "logger") is Action<string, string, Dictionary<string, object?>> logger)
            {
                _logger = logger;
            }
            else
            {
                var minLevel = Levels.TryGetValue(FoptStr(options, "level", "info"), out var ml)
                    ? ml : 1;
                _logger = (level, msg, attrs) =>
                {
                    var n = Levels.TryGetValue(level, out var lv) ? lv : 1;
                    if (n < minLevel)
                    {
                        return;
                    }
                    var parts = attrs.Select(kv => kv.Key + "=" + kv.Value);
                    Console.Error.WriteLine(
                        $"level={level.ToUpperInvariant()} name=log msg={msg} " +
                        string.Join(" ", parts));
                };
            }
        }
    }

    public override void PostConstruct(Context ctx) => Loghook("PostConstruct", ctx, "");
    public override void PostConstructEntity(Context ctx) => Loghook("PostConstructEntity", ctx, "");
    public override void SetData(Context ctx) => Loghook("SetData", ctx, "");
    public override void GetData(Context ctx) => Loghook("GetData", ctx, "");
    public override void SetMatch(Context ctx) => Loghook("SetMatch", ctx, "");
    public override void GetMatch(Context ctx) => Loghook("GetMatch", ctx, "");
    public override void PrePoint(Context ctx) => Loghook("PrePoint", ctx, "");
    public override void PreSpec(Context ctx) => Loghook("PreSpec", ctx, "");
    public override void PreRequest(Context ctx) => Loghook("PreRequest", ctx, "");
    public override void PreResponse(Context ctx) => Loghook("PreResponse", ctx, "");
    public override void PreResult(Context ctx) => Loghook("PreResult", ctx, "");

    private void Loghook(string hook, Context ctx, string level)
    {
        if (_logger == null)
        {
            return;
        }

        if (level == "")
        {
            level = "info";
        }

        var attrs = new Dictionary<string, object?>
        {
            ["hook"] = hook,
        };

        if (ctx.Op != null)
        {
            attrs["op"] = ctx.Op.Name;
        }

        if (ctx.Spec != null)
        {
            attrs["spec"] = ctx.Spec.Method + " " + ctx.Spec.Path;
        }

        _logger(level, "hook", attrs);
    }
}
