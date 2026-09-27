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

        var transform = Helpers.ToMapAny(StructUtils.GetProp(point, "transform"));
        if (transform == null)
        {
            return StripAction(ctx.Reqdata);
        }

        var reqform = StructUtils.GetProp(transform, "req");
        if (reqform == null)
        {
            return StripAction(ctx.Reqdata);
        }

        var reqdata = StructUtils.Transform(new Dictionary<string, object?>
        {
            ["reqdata"] = ctx.Reqdata,
        }, reqform);

        return StripAction(reqdata);
    }

    // `$action` selects the point (see MakePointUtil); it is never an API
    // field, so the body is a copy without it. The caller's map is left
    // untouched.
    private static object? StripAction(object? reqdata)
    {
        if (reqdata is not IDictionary<string, object?> src || !src.ContainsKey("$action"))
        {
            return reqdata;
        }
        var body = new Dictionary<string, object?>();
        foreach (var kv in src)
        {
            if ("$action" != kv.Key)
            {
                body[kv.Key] = kv.Value;
            }
        }
        return body;
    }
}
