// Univec SDK utility: makeFetchDef.

using Voxgig.Struct;

namespace UnivecSdk.Util;

public static partial class SdkUtility
{
    internal static Dictionary<string, object?> MakeFetchDefUtil(Context ctx)
    {
        var spec = ctx.Spec ?? throw ctx.MakeError("fetchdef_no_spec",
            "Expected context spec property to be defined.");

        ctx.Result ??= new Result(new Dictionary<string, object?>());

        spec.Step = "prepare";

        var url = ctx.Utility!.MakeUrl(ctx);

        spec.Url = url;

        var fetchdef = new Dictionary<string, object?>
        {
            ["url"] = url,
            ["method"] = spec.Method,
            ["headers"] = spec.Headers,
        };

        if (spec.Body != null)
        {
            fetchdef["body"] = spec.Body is Dictionary<string, object?>
                ? StructUtils.Jsonify(spec.Body)
                : spec.Body;
        }

        return fetchdef;
    }
}
