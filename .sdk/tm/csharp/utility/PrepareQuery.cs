// Univec SDK utility: prepareQuery - reqmatch keys that are not path
// params become query parameters.

using Voxgig.Struct;

namespace UnivecSdk.Util;

public static partial class SdkUtility
{
    internal static Dictionary<string, object?> PrepareQueryUtil(Context ctx)
    {
        var point = ctx.Point;
        var reqmatch = ctx.Reqmatch ?? new Dictionary<string, object?>();

        List<object?>? paramnames = null;
        if (point != null && StructUtils.GetProp(point, "params") is List<object?> pl)
        {
            paramnames = pl;
        }
        paramnames ??= new List<object?>();

        var query = new Dictionary<string, object?>();
        foreach (var item in StructUtils.Items(reqmatch))
        {
            var key = item[0] as string ?? "";
            var val = item[1];
            if (val != null && !ContainsStr(paramnames, key))
            {
                query[key] = val;
            }
        }

        return query;
    }

    private static bool ContainsStr(List<object?> list, string s)
    {
        return list.Any(v => v is string vs && vs == s);
    }
}
