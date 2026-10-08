// Univec SDK utility: makeUrl - substitute params and append the
// query string.

using System.Text.RegularExpressions;

using Voxgig.Struct;

namespace UnivecSdk.Util;

public static partial class SdkUtility
{
    private static readonly Regex PlaceholderRe = new Regex("\\{[^{}/]+\\}");

    internal static string MakeUrlUtil(Context ctx)
    {
        var spec = ctx.Spec ?? throw ctx.MakeError("url_no_spec",
            "Expected context spec property to be defined.");
        var result = ctx.Result ?? throw ctx.MakeError("url_no_result",
            "Expected context result property to be defined.");

        var url = StructUtils.Join(
            StructUtils.Jt(spec.Base, spec.Prefix, spec.Path, spec.Suffix), "/", true);
        var resmatch = new Dictionary<string, object?>();

        // Sent with the request, never recorded as the entity's match.
        var authquery = spec.AuthQuery;

        // A route the definition ends with a slash keeps it: a server such as
        // a Django REST one redirects or refuses the route without it.
        if (ctx.Point != null && StructUtils.GetProp(ctx.Point, "orig") is string orig &&
            orig.EndsWith("/") && string.IsNullOrEmpty(spec.Suffix) && !url.EndsWith("/"))
        {
            url += "/";
        }

        foreach (var item in StructUtils.Items(spec.Params))
        {
            var key = item[0] as string ?? "";
            var val = item[1];
            if (val != null)
            {
                var re = new Regex("\\{" + StructUtils.EscRe(key) + "\\}");
                url = re.Replace(url, StructUtils.EscUrl(StructUtils.Stringify(val)));
                resmatch[key] = val;
            }
        }

        // A placeholder left in the route would send the request to the wrong
        // route. The base's own placeholders are server variables, resolved
        // with the options.
        var baseUrl = (spec.Base ?? "").TrimEnd('/');
        var route = url.StartsWith(baseUrl, System.StringComparison.Ordinal) ? url.Substring(baseUrl.Length) : url;
        var unfilled = PlaceholderRe.Matches(route).Select(m => m.Value).ToList();
        if (unfilled.Count > 0)
        {
            throw ctx.MakeError("url_param_missing",
                "URL path has no value for " + string.Join(", ", unfilled) + ".");
        }

        // Append query string from spec.Query.
        var qsep = "?";
        foreach (var item in StructUtils.Items(spec.Query))
        {
            var key = item[0] as string ?? "";
            var val = item[1];
            if (val != null)
            {
                url += qsep + StructUtils.EscUrl(key) + "=" +
                    StructUtils.EscUrl(StructUtils.Stringify(val));
                qsep = "&";
                if (!authquery.Contains(key))
                {
                    resmatch[key] = val;
                }
            }
        }

        result.Resmatch = resmatch;

        return url;
    }
}
