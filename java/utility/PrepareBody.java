package voxgig.univecsdk.utility;

import voxgig.univecsdk.core.Context;

final class PrepareBody {

  private PrepareBody() {}

  static Object prepareBody(Context ctx) {
    if ("data".equals(ctx.op.input)) {
      return ctx.utility.transformRequest.apply(ctx);
    }

    return null;
  }
}
