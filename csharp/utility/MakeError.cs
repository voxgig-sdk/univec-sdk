// Univec SDK utility: makeError - the single error surface of the
// pipeline. Throws the wrapped UnivecError unless the per-call ctrl
// disables throwing (ctrl.throw == false), in which case it returns the
// (possibly nil) result data instead.

namespace UnivecSdk.Util;

public static partial class SdkUtility
{
    internal static object? MakeErrorUtil(Context ctx, Exception? err)
    {
        ctx ??= new Context(new Dictionary<string, object?>(), null);

        var op = ctx.Op ?? new Operation(new Dictionary<string, object?>());
        var opname = op.Name;
        if (opname == "" || opname == "_")
        {
            opname = "unknown operation";
        }

        var result = ctx.Result ?? new Result(new Dictionary<string, object?>());
        result.Ok = false;

        err ??= result.Err;
        err ??= ctx.MakeError("unknown", "unknown error");

        var errmsg = err.Message;
        var msg = "UnivecSDK: " + opname + ": " + errmsg;

        result.Err = null;

        var spec = ctx.Spec;

        // The context stays reachable on the error for a debugger; the error
        // type keeps it out of every serialiser.
        var sdkErr = new UnivecError(
            err is UnivecError se ? se.Code : "", msg, ctx);

        CleanUtil(ctx, sdkErr);

        // Promote the HTTP status to the top level, so a consumer can branch on
        // err.Status instead of reaching into err.ResultVal.
        sdkErr.Status = result.Status;

        // Reached from RunOp's catch as well as from Done, and a stage that
        // throws never reaches Done's cleaning.
        if (ctx.Ctrl.Explain != null)
        {
            CleanExplainUtil(ctx);
            ctx.Ctrl.Explain["err"] = new Dictionary<string, object?>
            {
                ["code"] = sdkErr.Code,
                ["message"] = sdkErr.Message,
                ["status"] = sdkErr.Status,
            };
        }

        sdkErr.ResultVal = CleanUtil(ctx, result);
        sdkErr.SpecVal = CleanUtil(ctx, spec);

        ctx.Ctrl.Err = sdkErr;

        // Fire PreUnexpected so observability features (metrics, telemetry,
        // audit, debug) close/record error paths that never reach PreDone
        // (e.g. a PrePoint rbac short-circuit). Fires after ctx.Ctrl.Err is set
        // so hooks can read the error; features guard against double-recording
        // when PreDone already fired.
        if (ctx.Utility?.FeatureHook != null)
        {
            ctx.Utility.FeatureHook(ctx, "PreUnexpected");
        }

        if (ctx.Ctrl.Throw == false)
        {
            return result.Resdata;
        }

        throw sdkErr;
    }
}
