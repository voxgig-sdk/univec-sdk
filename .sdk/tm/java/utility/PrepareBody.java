package JAVAPACKAGE.utility;

import JAVAPACKAGE.core.Context;

final class PrepareBody {

  private PrepareBody() {}

  static Object prepareBody(Context ctx) {
    if ("data".equals(ctx.op.input)) {
      if (Media.isRawRequest(ctx.point)) {
        return Media.rawBody(ctx.reqdata);
      }
      return ctx.utility.transformRequest.apply(ctx);
    }

    return null;
  }
}
