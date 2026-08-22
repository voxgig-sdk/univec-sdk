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
            return ctx.Reqdata;
        }

        var reqform = StructUtils.GetProp(transform, "req");
        if (reqform == null)
        {
            return ctx.Reqdata;
        }

        var reqdata = StructUtils.Transform(new Dictionary<string, object?>
        {
            ["reqdata"] = ctx.Reqdata,
        }, reqform);

        return reqdata;
    }
}
