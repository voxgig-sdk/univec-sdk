// Univec SDK utility: done - final result extraction.

namespace UnivecSdk.Util;

public static partial class SdkUtility
{
    internal static object? DoneUtil(Context ctx)
    {
        if (ctx.Ctrl.Explain != null)
        {
            ctx.Ctrl.Explain =
                CleanUtil(ctx, ctx.Ctrl.Explain) as Dictionary<string, object?>;
            if (ctx.Ctrl.Explain != null &&
                ctx.Ctrl.Explain.TryGetValue("result", out var explainResult) &&
                explainResult is Dictionary<string, object?> rm)
            {
                rm.Remove("err");
            }
        }

        if (ctx.Result != null && ctx.Result.Ok)
        {
            return ctx.Result.Resdata;
        }

        return MakeErrorUtil(ctx, null);
    }
}
