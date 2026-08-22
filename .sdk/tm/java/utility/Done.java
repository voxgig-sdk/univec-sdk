package JAVAPACKAGE.utility;

import java.util.Map;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Helpers;

@SuppressWarnings({"unchecked"})
final class Done {

  private Done() {}

  static Object done(Context ctx) {
    if (ctx.ctrl.explain != null) {
      ctx.ctrl.explain = (Map<String, Object>) Clean.clean(ctx, ctx.ctrl.explain);
      Object explainResult = ctx.ctrl.explain.get("result");
      Map<String, Object> rm = Helpers.toMapAny(explainResult);
      if (rm != null) {
        rm.remove("err");
      }
    }

    if (ctx.result != null && ctx.result.ok) {
      return ctx.result.resdata;
    }

    return MakeError.makeError(ctx, null);
  }
}
