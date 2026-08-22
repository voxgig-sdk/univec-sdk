// Univec SDK utility: fetcher - the default HttpClient transport,
// mode/test blocking, and the injectable system.fetch override.

using System.Net.Http;
using System.Text;
using System.Text.Json;

using Voxgig.Struct;

namespace UnivecSdk.Util;

public static partial class SdkUtility
{
    private static readonly HttpClient DefaultHttpClient = new();

    // Non-following twin of DefaultHttpClient. The station feature's
    // middleware sets `redirect: manual` on the fetch definition under a
    // hosts egress policy: a 3xx must come back as a response like any
    // other, because an automatic follow would carry injected credentials
    // to a Location no policy approved (the ts donor's fetch honours the
    // same key natively; redirect policy is per-handler in .NET, hence a
    // second client).
    private static readonly HttpClient ManualRedirectHttpClient = new(
        new HttpClientHandler
        {
            AllowAutoRedirect = false,
        });

    // Proxy-routed clients, cached per proxy URL and redirect policy (see
    // the proxy feature's fetchdef annotation).
    private static readonly Dictionary<string, HttpClient> ProxyClients = new();
    private static readonly object ProxyClientsLock = new();

    private static HttpClient ClientFor(Dictionary<string, object?> fetchdef)
    {
        var manual = fetchdef.TryGetValue("redirect", out var rraw) &&
            rraw is string redirect && redirect == "manual";

        if (fetchdef.TryGetValue("proxy", out var raw) && raw is string proxy && proxy != "")
        {
            lock (ProxyClientsLock)
            {
                var key = (manual ? "manual|" : "auto|") + proxy;
                if (!ProxyClients.TryGetValue(key, out var client))
                {
                    client = new HttpClient(new HttpClientHandler
                    {
                        Proxy = new System.Net.WebProxy(proxy),
                        UseProxy = true,
                        AllowAutoRedirect = !manual,
                    });
                    ProxyClients[key] = client;
                }
                return client;
            }
        }
        return manual ? ManualRedirectHttpClient : DefaultHttpClient;
    }

    internal static Dictionary<string, object?> DefaultHttpFetch(
        string fullurl, Dictionary<string, object?> fetchdef)
    {
        var method = fetchdef.TryGetValue("method", out var mraw) && mraw is string m && m != ""
            ? m : "GET";

        using var req = new HttpRequestMessage(new HttpMethod(method), fullurl);

        if (fetchdef.TryGetValue("body", out var braw) && braw is string body && body != "")
        {
            req.Content = new StringContent(body, Encoding.UTF8, "application/json");
        }

        var hasUA = false;
        if (fetchdef.TryGetValue("headers", out var hraw) &&
            hraw is Dictionary<string, object?> headers)
        {
            foreach (var kv in headers)
            {
                if (kv.Value is string sv)
                {
                    if (string.Equals(kv.Key, "user-agent", StringComparison.OrdinalIgnoreCase))
                    {
                        hasUA = true;
                    }
                    if (string.Equals(kv.Key, "content-type", StringComparison.OrdinalIgnoreCase))
                    {
                        // Content headers live on the content object.
                        req.Content ??= new StringContent("", Encoding.UTF8);
                        req.Content.Headers.Remove("Content-Type");
                        req.Content.Headers.TryAddWithoutValidation("Content-Type", sv);
                        continue;
                    }
                    req.Headers.TryAddWithoutValidation(kv.Key, sv);
                }
            }
        }
        // Default User-Agent - some CDNs block requests without one. Use a
        // Mozilla-shaped UA unless the caller already set one.
        if (!hasUA)
        {
            req.Headers.TryAddWithoutValidation("User-Agent",
                "Mozilla/5.0 (compatible; UnivecSDK/1.0)");
        }

        using var resp = ClientFor(fetchdef).Send(req, HttpCompletionOption.ResponseContentRead);

        var bodyText = resp.Content.ReadAsStringAsync().GetAwaiter().GetResult();

        var resheaders = new Dictionary<string, object?>();
        foreach (var kv in resp.Headers.Concat(resp.Content.Headers))
        {
            var vals = kv.Value.ToList();
            resheaders[kv.Key.ToLowerInvariant()] =
                vals.Count == 1 ? vals[0] : string.Join(", ", vals);
        }

        object? jsonBody = null;
        if (bodyText.Length > 0)
        {
            try
            {
                var el = JsonSerializer.Deserialize<JsonElement>(bodyText);
                jsonBody = JsonToNative(el);
            }
            catch (JsonException)
            {
                jsonBody = null;
            }
        }

        var statusText = resp.ReasonPhrase ?? "";

        return new Dictionary<string, object?>
        {
            ["status"] = (int)resp.StatusCode,
            ["statusText"] = statusText,
            ["headers"] = resheaders,
            ["json"] = (Func<object?>)(() => jsonBody),
            ["body"] = bodyText,
        };
    }

    // JsonToNative converts a JsonElement tree into the loose object model
    // (Dictionary<string, object?> / List<object?> / string / long / double
    // / bool / null) the vendored struct utility manipulates.
    public static object? JsonToNative(JsonElement el)
    {
        return el.ValueKind switch
        {
            JsonValueKind.Object => el.EnumerateObject()
                .ToDictionary(p => p.Name, p => JsonToNative(p.Value)),
            JsonValueKind.Array => el.EnumerateArray()
                .Select(JsonToNative)
                .ToList(),
            JsonValueKind.String => el.GetString(),
            JsonValueKind.Number => el.TryGetInt64(out var l) ? l : el.GetDouble(),
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => null,
        };
    }

    internal static object? FetcherUtil(Context ctx, string fullurl,
        Dictionary<string, object?> fetchdef)
    {
        if (ctx.Client!.Mode != "live")
        {
            throw ctx.MakeError("fetch_mode_block",
                "Request blocked by mode: \"" + ctx.Client.Mode +
                "\" (URL was: \"" + fullurl + "\")");
        }

        var options = ctx.Client.OptionsMap();
        if (Equals(StructUtils.GetPath(options, StructUtils.Jt("feature", "test", "active")), true))
        {
            throw ctx.MakeError("fetch_test_block",
                "Request blocked as test feature is active" +
                " (URL was: \"" + fullurl + "\")");
        }

        var sysFetch = StructUtils.GetPath(options, StructUtils.Jt("system", "fetch"));

        if (sysFetch == null)
        {
            return DefaultHttpFetch(fullurl, fetchdef);
        }

        if (sysFetch is Func<string, Dictionary<string, object?>, Dictionary<string, object?>> fetchFunc)
        {
            return fetchFunc(fullurl, fetchdef);
        }
        if (sysFetch is Func<string, Dictionary<string, object?>, object?> fetchFuncAny)
        {
            return fetchFuncAny(fullurl, fetchdef);
        }

        throw ctx.MakeError("fetch_invalid", "system.fetch is not a valid function");
    }
}
