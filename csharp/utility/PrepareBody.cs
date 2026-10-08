// Univec SDK utility: prepareBody.

namespace UnivecSdk.Util;

public static partial class SdkUtility
{
    internal static object? PrepareBodyUtil(Context ctx)
    {
        var op = ctx.Op!;

        if (op.Input == "data")
        {
            if (IsRawRequest(ctx.Point))
            {
                return RawBodyOf(ctx.Reqdata);
            }
            var body = ctx.Utility!.TransformRequest(ctx);
            return body;
        }

        return null;
    }
}
