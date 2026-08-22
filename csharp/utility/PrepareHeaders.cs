// Univec SDK utility: prepareHeaders.

using Voxgig.Struct;

namespace UnivecSdk.Util;

public static partial class SdkUtility
{
    internal static Dictionary<string, object?> PrepareHeadersUtil(Context ctx)
    {
        var options = ctx.Client!.OptionsMap();

        var headers = StructUtils.GetProp(options, "headers");
        if (headers == null)
        {
            return new Dictionary<string, object?>();
        }

        return StructUtils.Clone(headers) as Dictionary<string, object?>
            ?? new Dictionary<string, object?>();
    }
}
