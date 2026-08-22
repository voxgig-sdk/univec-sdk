// Univec SDK utility: resultHeaders.

namespace UnivecSdk.Util;

public static partial class SdkUtility
{
    internal static Result ResultHeadersUtil(Context ctx)
    {
        var response = ctx.Response;
        var result = ctx.Result;

        if (result != null)
        {
            if (response?.Headers is Dictionary<string, object?> hm)
            {
                result.Headers = hm;
            }
            else
            {
                result.Headers = new Dictionary<string, object?>();
            }
        }

        return result!;
    }
}
