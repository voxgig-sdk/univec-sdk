// Univec SDK utility: param - resolve a parameter value from the
// request/entity state (reqmatch, match, reqdata, data), honouring point
// aliases.

using Voxgig.Struct;

namespace UnivecSdk.Util;

public static partial class SdkUtility
{
    internal static object? ParamUtil(Context ctx, object? paramdef)
    {
        var point = ctx.Point;
        var spec = ctx.Spec;
        var match = ctx.Match;
        var reqmatch = ctx.Reqmatch;
        var data = ctx.Data;
        var reqdata = ctx.Reqdata;

        var pt = StructUtils.Typify(paramdef);

        string key;
        if (0 < (T.Str & pt))
        {
            key = paramdef as string ?? "";
        }
        else
        {
            key = StructUtils.GetProp(paramdef, "name") as string ?? "";
        }

        var akey = "";
        if (point != null)
        {
            var alias = Helpers.ToMapAny(StructUtils.GetProp(point, "alias"));
            if (alias != null && StructUtils.GetProp(alias, key) is string ak)
            {
                akey = ak;
            }
        }

        var val = StructUtils.GetProp(reqmatch, key);

        val ??= StructUtils.GetProp(match, key);

        if (val == null && akey != "")
        {
            if (spec != null)
            {
                spec.Alias[akey] = key;
            }
            val = StructUtils.GetProp(reqmatch, akey);
        }

        val ??= StructUtils.GetProp(reqdata, key);

        val ??= StructUtils.GetProp(data, key);

        if (val == null && akey != "")
        {
            val = StructUtils.GetProp(reqdata, akey);
            val ??= StructUtils.GetProp(data, akey);
        }

        return val;
    }
}
