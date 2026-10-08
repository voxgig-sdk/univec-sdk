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

        var paramnames = new List<object?>();
        if (point != null && StructUtils.GetProp(point, "params") is List<object?> pl)
        {
            paramnames.AddRange(pl);
        }
        // A path parameter travels in the path. The generated config lists them
        // as args.params, which PrepareParams reads; params is the older list.
        if (point != null &&
            StructUtils.GetPath(point, StructUtils.Jt("args", "params")) is List<object?> apl)
        {
            foreach (var pd in apl)
            {
                if (StructUtils.GetProp(pd, "name") is string name)
                {
                    paramnames.Add(name);
                }
            }
        }

        // A header or cookie parameter travels in the headers, which
        // PrepareHeaders fills, unless a query parameter shares its name: then
        // both are sent.
        var declared = new List<object?>();
        if (point != null &&
            StructUtils.GetPath(point, StructUtils.Jt("args", "query")) is List<object?> dql)
        {
            foreach (var qd in dql)
            {
                declared.Add(StructUtils.GetProp(qd, "name"));
            }
        }
        if (point != null &&
            StructUtils.GetPath(point, StructUtils.Jt("args", "header")) is List<object?> ahl)
        {
            foreach (var hd in ahl)
            {
                if (StructUtils.GetProp(hd, "name") is string hname && !declared.Contains(hname))
                {
                    paramnames.Add(hname);
                }
            }
        }
        if (point != null &&
            StructUtils.GetPath(point, StructUtils.Jt("args", "cookie")) is List<object?> acl)
        {
            foreach (var cd in acl)
            {
                if (StructUtils.GetProp(cd, "name") is string cname && !declared.Contains(cname))
                {
                    paramnames.Add(cname);
                }
            }
        }

        // A query parameter travels under the name the definition gives it,
        // its orig, which the model may have renamed for the caller.
        var wire = new Dictionary<string, string>();
        if (point != null &&
            StructUtils.GetPath(point, StructUtils.Jt("args", "query")) is List<object?> aql)
        {
            foreach (var qd in aql)
            {
                if (StructUtils.GetProp(qd, "name") is string qname &&
                    StructUtils.GetProp(qd, "orig") is string qorig && qorig != "")
                {
                    wire[qname] = qorig;
                }
            }
        }

        var query = new Dictionary<string, object?>();
        foreach (var item in StructUtils.Items(reqmatch))
        {
            var key = item[0] as string ?? "";
            var val = item[1];
            if (val != null && "$action" != key && !ContainsStr(paramnames, key))
            {
                query[wire.TryGetValue(key, out var wkey) ? wkey : key] = val;
            }
        }

        // A create or update passes its query arguments in its data.
        foreach (var arg in CallArgs(ctx, "query"))
        {
            if (arg.Val != null && !ContainsStr(paramnames, arg.Name))
            {
                query[arg.Wire] = arg.Val;
            }
        }

        return query;
    }

    private static bool ContainsStr(List<object?> list, string s)
    {
        return list.Any(v => v is string vs && vs == s);
    }
}
