// Univec SDK utility: transformResponse - apply the point's response
// transform (when defined) to derive the result data.

using Voxgig.Struct;

namespace UnivecSdk.Util;

public static partial class SdkUtility
{
    internal static object? TransformResponseUtil(Context ctx)
    {
        var spec = ctx.Spec;
        var result = ctx.Result;
        var point = ctx.Point;

        if (spec != null)
        {
            spec.Step = "resform";
        }

        if (result == null || !result.Ok)
        {
            return null;
        }

        var transform = Helpers.ToMapAny(StructUtils.GetProp(point, "transform"));
        if (transform == null)
        {
            return null;
        }

        var resform = StructUtils.GetProp(transform, "res");
        if (resform == null)
        {
            return null;
        }

        var resdata = StructUtils.Transform(new Dictionary<string, object?>
        {
            ["ok"] = result.Ok,
            ["status"] = result.Status,
            ["statusText"] = result.StatusText,
            ["headers"] = result.Headers,
            ["body"] = result.Body,
            ["err"] = result.Err,
            ["resdata"] = result.Resdata,
            ["resmatch"] = result.Resmatch,
        }, resform);

        result.Resdata = resdata;
        return resdata;
    }
}
