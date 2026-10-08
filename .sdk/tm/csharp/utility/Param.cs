// Univec SDK utility: param - resolve a parameter value from the
// request/entity state (reqmatch, match, reqdata, data), honouring point
// aliases.

using Voxgig.Struct;

namespace UnivecSdk.Util;

public static partial class SdkUtility
{
    internal static object? ParamUtil(Context ctx, object? paramdef)
    {
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

        var akey = ParamAlias(ctx.Point, key);
        if (ctx.Spec != null && akey != "" &&
            StructUtils.GetProp(ctx.Reqmatch, key) == null && StructUtils.GetProp(ctx.Match, key) == null)
        {
            ctx.Spec.Alias[akey] = key;
        }

        return ParamValue(ctx, ctx.Point, key);
    }

    // The name a point gives a parameter in the call, if it renames it.
    private static string ParamAlias(Dictionary<string, object?>? point, string key)
    {
        if (point != null)
        {
            var alias = Helpers.ToMapAny(StructUtils.GetProp(point, "alias"));
            if (alias != null && StructUtils.GetProp(alias, key) is string ak)
            {
                return ak;
            }
        }
        return "";
    }

    // The value the call or its entity gives a point's parameter, under its
    // name or the point's alias for it.
    internal static object? ParamValue(Context ctx, Dictionary<string, object?>? point, string key)
    {
        var akey = ParamAlias(point, key);

        var val = StructUtils.GetProp(ctx.Reqmatch, key);

        val ??= StructUtils.GetProp(ctx.Match, key);

        if (val == null && akey != "")
        {
            val = StructUtils.GetProp(ctx.Reqmatch, akey);
        }

        val ??= StructUtils.GetProp(ctx.Reqdata, key);

        val ??= StructUtils.GetProp(ctx.Data, key);

        if (val == null && akey != "")
        {
            val = StructUtils.GetProp(ctx.Reqdata, akey);
            val ??= StructUtils.GetProp(ctx.Data, akey);
        }

        return val;
    }

    // The arguments a point declares in one location, query or header, each
    // with the name it travels under and the value this call passes in its
    // match or else its data. Unlike a path parameter, the entity's stored
    // match and data never supply one.
    internal static List<(string Name, string Wire, object? Val)> CallArgs(Context ctx, string kind)
    {
        var args = new List<(string Name, string Wire, object? Val)>();
        if (ctx.Point != null &&
            StructUtils.GetPath(ctx.Point, StructUtils.Jt("args", kind)) is List<object?> defs)
        {
            foreach (var ad in defs)
            {
                if (StructUtils.GetProp(ad, "name") is not string name || name == "")
                {
                    continue;
                }
                var wire = StructUtils.GetProp(ad, "orig") is string orig && orig != "" ? orig : name;
                var val = ctx.Reqmatch == null ? null : StructUtils.GetProp(ctx.Reqmatch, name);
                if (val == null && ctx.Reqdata != null)
                {
                    val = StructUtils.GetProp(ctx.Reqdata, name);
                }
                args.Add((name, wire, val));
            }
        }
        return args;
    }
}
