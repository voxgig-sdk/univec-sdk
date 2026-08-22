package JAVAPACKAGE.utility;

import java.util.LinkedHashMap;
import java.util.Map;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Result;
import JAVAPACKAGE.core.SdkError;
import JAVAPACKAGE.core.Spec;

// makeError finalises a failed operation: wraps the causing error in an
// SdkError carrying the cleaned result and spec, records it on ctx.ctrl,
// and either throws it (default) or — when ctrl.throw is false — returns
// the result's fallback resdata instead.
final class MakeError {

  private MakeError() {}

  static Object makeError(Context ctx, RuntimeException err) {
    if (ctx == null) {
      ctx = new Context(new LinkedHashMap<>(), null);
    }

    String opname = ctx.op == null ? "" : ctx.op.name;
    if ("".equals(opname) || "_".equals(opname)) {
      opname = "unknown operation";
    }

    Result result = ctx.result;
    if (result == null) {
      result = new Result(new LinkedHashMap<>());
    }
    result.ok = false;

    if (err == null) {
      err = result.err;
    }
    if (err == null) {
      err = ctx.makeError("unknown", "unknown error");
    }

    String errmsg = err.getMessage() == null ? String.valueOf(err) : err.getMessage();
    String msg = "UnivecSDK: " + opname + ": " + errmsg;
    msg = (String) Clean.clean(ctx, msg);

    result.err = null;

    Spec spec = ctx.spec;

    if (ctx.ctrl.explain != null) {
      Map<String, Object> errRecord = new LinkedHashMap<>();
      errRecord.put("message", msg);
      ctx.ctrl.explain.put("err", errRecord);
    }

    String code = "";
    if (err instanceof SdkError) {
      code = ((SdkError) err).code;
    }

    SdkError sdkErr = new SdkError(code, msg, ctx);
    sdkErr.result = Clean.clean(ctx, result);
    sdkErr.spec = Clean.clean(ctx, spec);

    // Promote the HTTP status to the top level, so a consumer can branch on
    // `err.status` / `err.notFound()` instead of reaching into `err.result`.
    sdkErr.status = result.status;

    ctx.ctrl.err = sdkErr;

    // Fire PreUnexpected so observability features (metrics, telemetry, audit,
    // debug) close/record error paths that never reach PreDone (e.g. a PrePoint
    // rbac short-circuit). Fires after ctx.ctrl.err is set so hooks can read the
    // error; features guard against double-recording when PreDone already fired.
    if (ctx.utility != null && ctx.utility.featureHook != null) {
      ctx.utility.featureHook.apply(ctx, "PreUnexpected");
    }

    if (Boolean.FALSE.equals(ctx.ctrl.throwing)) {
      return result.resdata;
    }

    throw sdkErr;
  }
}
