package voxgig.univecsdk.utility;

import java.util.LinkedHashMap;
import java.util.Map;

import voxgig.univecsdk.core.Context;
import voxgig.univecsdk.core.Helpers;
import voxgig.univecsdk.utility.struct.Struct;

final class TransformRequest {

  private TransformRequest() {}

  static Object transformRequest(Context ctx) {
    if (ctx.spec != null) {
      ctx.spec.step = "reqform";
    }

    Map<String, Object> transform =
        Helpers.toMapAny(Struct.getprop(ctx.point, "transform"));
    if (transform == null) {
      return ctx.reqdata;
    }

    Object reqform = Struct.getprop(transform, "req", null);
    if (reqform == null) {
      return ctx.reqdata;
    }

    Map<String, Object> data = new LinkedHashMap<>();
    data.put("reqdata", ctx.reqdata);

    return Struct.transform(data, reqform);
  }
}
