// Outbound HTTP(S) proxy support. Wraps the active transport and annotates
// each request's fetch definition with the proxy target (`fetchdef.proxy`).
// The default HttpClient transport honours the annotation by routing the
// request through an HttpClientHandler with Proxy set (see
// utility/Fetcher.cs); custom transports can do the same. The proxy target
// comes from options (`url`) or, when `fromEnv` is set, the standard
// HTTPS_PROXY / HTTP_PROXY / NO_PROXY environment variables. Hosts matching
// `noProxy` bypass the proxy.

using System.Text.RegularExpressions;

using static UnivecSdk.Feature.FeatureOptions;

namespace UnivecSdk.Feature;

public class ProxyFeature : BaseFeature
{
    private UnivecSDK? _client;
    private Dictionary<string, object?>? _options;
    private List<string> _noProxy = new();

    // Activity tracking (mirrors the ts client._proxy record).
    public int Routed;
    public string Url = "";

    private static readonly Regex HostRe = new(@"^[a-z]+://([^/:]+)", RegexOptions.IgnoreCase);

    public ProxyFeature()
    {
        Version = "0.0.1";
        Name = "proxy";
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

        Url = FoptStr(_options, "url", "");
        var noProxy = FoptStrList(_options, "noProxy");

        if (FoptBool(_options, "fromEnv", false))
        {
            if (Url == "")
            {
                Url = FirstEnv("HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy");
            }
            if (noProxy == null)
            {
                var np = FirstEnv("NO_PROXY", "no_proxy");
                if (np != "")
                {
                    noProxy = np.Split(',').ToList();
                }
            }
        }

        _noProxy = new List<string>();
        foreach (var raw in noProxy ?? new List<string>())
        {
            var np = raw.Trim();
            if (np != "")
            {
                _noProxy.Add(np);
            }
        }

        var inner = ctx.Utility!.Fetcher;

        ctx.Utility.Fetcher = (ctx2, url, fetchdef) =>
        {
            fetchdef = Route(url, fetchdef);
            return inner(ctx2, url, fetchdef);
        };
    }

    private Dictionary<string, object?> Route(string url, Dictionary<string, object?> fetchdef)
    {
        if (Url == "" || Bypass(url))
        {
            return fetchdef;
        }

        var routed = new Dictionary<string, object?>(fetchdef)
        {
            ["proxy"] = Url,
        };

        Routed++;
        return routed;
    }

    private bool Bypass(string url)
    {
        if (_noProxy.Count == 0)
        {
            return false;
        }
        var host = url;
        var m = HostRe.Match(url);
        if (m.Success)
        {
            host = m.Groups[1].Value;
        }
        foreach (var np in _noProxy)
        {
            if (np == "*")
            {
                return true;
            }
            if (host == np || host.EndsWith("." + np.TrimStart('.')))
            {
                return true;
            }
        }
        return false;
    }

    private static string FirstEnv(params string[] names)
    {
        foreach (var name in names)
        {
            var v = Environment.GetEnvironmentVariable(name);
            if (!string.IsNullOrEmpty(v))
            {
                return v;
            }
        }
        return "";
    }
}
