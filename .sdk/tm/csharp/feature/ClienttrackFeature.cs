// Client tracking. Establishes a stable per-client session id at
// construction and stamps identifying headers on every request: a
// `User-Agent` (`<clientName>/<clientVersion>`), an `X-Client-Id` (session),
// and a fresh per-request `X-Request-Id`. This lets a server correlate all
// traffic from one SDK instance and each individual call. Header names,
// client name/version and the id generator (`idgen`) are configurable;
// caller-provided User-Agent / X-Client-Id values are never clobbered.

using static UnivecSdk.Feature.FeatureOptions;

namespace UnivecSdk.Feature;

public class ClienttrackFeature : BaseFeature
{
    private UnivecSDK? _client;
    private Dictionary<string, object?>? _options;

    // Activity tracking (mirrors the ts client._clienttrack record).
    public string Session = "";
    public int Requests;
    public string LastRequestID = "";
    public string ClientName = "";

    public ClienttrackFeature()
    {
        Version = "0.0.1";
        Name = "clienttrack";
        Active = true;
    }

    public override void Init(Context ctx, Dictionary<string, object?> options)
    {
        _client = ctx.Client;
        _options = options;
        Active = FoptBool(options, "active", false);
        Requests = 0;
    }

    public override void PostConstruct(Context ctx)
    {
        if (!Active)
        {
            return;
        }
        Session = FoptStr(_options, "sessionId", Genid("session"));
        ClientName = NameVersion();
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
        spec.Headers ??= new Dictionary<string, object?>();

        // Lazily establish the session when PostConstruct never fired.
        if (Session == "")
        {
            Session = FoptStr(_options, "sessionId", Genid("session"));
        }

        var h = FoptMap(_options, "headers");
        Requests++;
        var requestId = Genid("request");

        FheaderSetDefault(spec.Headers, FoptStr(h, "agent", "User-Agent"), NameVersion());
        FheaderSetDefault(spec.Headers, FoptStr(h, "client", "X-Client-Id"), Session);
        spec.Headers[FoptStr(h, "request", "X-Request-Id")] = requestId;

        LastRequestID = requestId;
        ClientName = NameVersion();
    }

    private string NameVersion()
    {
        var name = FoptStr(_options, "clientName", "Univec-SDK");
        var version = FoptStr(_options, "clientVersion", "0.0.1");
        return name + "/" + version;
    }

    private string Genid(string kind)
    {
        if (Opt(_options, "idgen") is Func<string, string> idgen)
        {
            return idgen(kind);
        }
        var id = string.Format("{0}-{1:x6}{2:x6}{3:x6}", kind[..1],
            Random.Shared.Next(0x1000000), Random.Shared.Next(0x1000000),
            Random.Shared.Next(0x1000000));
        if (id.Length > 20)
        {
            id = id[..20];
        }
        return id;
    }
}
