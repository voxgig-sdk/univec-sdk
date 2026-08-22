// Univec SDK utility: resultBasic - status/statusText plus 4xx/5xx
// error shaping.

namespace UnivecSdk.Util;

public static partial class SdkUtility
{
    internal static Result ResultBasicUtil(Context ctx)
    {
        var response = ctx.Response;
        var result = ctx.Result;

        if (result != null && response != null)
        {
            result.Status = response.Status;
            result.StatusText = response.StatusText;

            if (result.Status >= 400)
            {
                var msg = "request: " + result.Status + ": " + result.StatusText;
                if (result.Err != null)
                {
                    var prevmsg = result.Err.Message;
                    result.Err = ctx.MakeError("request_status", prevmsg + ": " + msg);
                }
                else
                {
                    result.Err = ctx.MakeError("request_status", msg);
                }
            }
            else if (response.Err != null)
            {
                result.Err = response.Err;
            }
        }

        return result!;
    }
}
