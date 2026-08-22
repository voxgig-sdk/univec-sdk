// Univec SDK utility: makeUrl - substitute params and append the
// query string.

using System.Text.RegularExpressions;

using Voxgig.Struct;

namespace UnivecSdk.Util;

public static partial class SdkUtility
{
    internal static string MakeUrlUtil(Context ctx)
    {
        var spec = ctx.Spec ?? throw ctx.MakeError("url_no_spec",
            "Expected context spec property to be defined.");
        var result = ctx.Result ?? throw ctx.MakeError("url_no_result",
            "Expected context result property to be defined.");

        var url = StructUtils.Join(
            StructUtils.Jt(spec.Base, spec.Prefix, spec.Path, spec.Suffix), "/", true);
        var resmatch = new Dictionary<string, object?>();

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
                resmatch[key] = val;
            }
        }

        result.Resmatch = resmatch;

        return url;
    }
}
