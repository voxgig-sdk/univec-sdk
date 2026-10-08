// Univec SDK utility: transformRequest - apply the point's request
// transform (when defined) to the request data.

using Voxgig.Struct;

namespace UnivecSdk.Util;

public static partial class SdkUtility
{
    internal static object? TransformRequestUtil(Context ctx)
    {
        var spec = ctx.Spec;
        var point = ctx.Point;

        if (spec != null)
        {
            spec.Step = "reqform";
        }

        var data = OmitKeys(ctx.Reqdata, RoutedArgNames(ctx));

        var transform = Helpers.ToMapAny(StructUtils.GetProp(point, "transform"));
        if (transform == null)
        {
            return StripAction(data);
        }

        var reqform = StructUtils.GetProp(transform, "req");
        if (reqform == null)
        {
            return StripAction(data);
        }

        var reqdata = StructUtils.Transform(new Dictionary<string, object?>
        {
            ["reqdata"] = data,
        }, reqform);

        return StripAction(reqdata);
    }

    // `$action` selects the point (see MakePointUtil); it is never an API
    // field, so the body is a copy without it. The caller's map is left
    // untouched.
    private static object? StripAction(object? reqdata)
    {
        return OmitKeys(reqdata, new List<string> { "$action" });
    }

    // A header, cookie or query argument travels where PrepareHeadersUtil or
    // PrepareQueryUtil sends it, so the body is built from the request data
    // without it, unless the point marks it as a field the body keeps.
    private static List<string> RoutedArgNames(Context ctx)
    {
        return CallArgs(ctx, "header").Concat(CallArgs(ctx, "cookie")).Concat(CallArgs(ctx, "query"))
            .Select(arg => arg.Name).Where(name => !FieldArg(ctx, name)).ToList();
    }

    private static bool FieldArg(Context ctx, string name)
    {
        if (ctx.Point == null)
        {
            return false;
        }
        foreach (var kind in new[] { "header", "cookie", "query" })
        {
            if (StructUtils.GetPath(ctx.Point, StructUtils.Jt("args", kind)) is List<object?> defs &&
                defs.Any(ad => name == StructUtils.GetProp(ad, "name") as string &&
                    StructUtils.GetProp(ad, "field") is true))
            {
                return true;
            }
        }
        return false;
    }

    private static object? OmitKeys(object? reqdata, List<string> names)
    {
        if (reqdata is not IDictionary<string, object?> src || !names.Exists(src.ContainsKey))
        {
            return reqdata;
        }
        var body = new Dictionary<string, object?>();
        foreach (var kv in src)
        {
            if (!names.Contains(kv.Key))
            {
                body[kv.Key] = kv.Value;
            }
        }
        return body;
    }
}
