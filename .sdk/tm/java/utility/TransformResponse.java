package JAVAPACKAGE.utility;

import java.util.LinkedHashMap;
import java.util.Map;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Helpers;
import JAVAPACKAGE.core.Result;
import JAVAPACKAGE.utility.struct.Struct;

final class TransformResponse {

  private TransformResponse() {}

  static Object transformResponse(Context ctx) {
    Result result = ctx.result;

    if (ctx.spec != null) {
      ctx.spec.step = "resform";
    }

    if (result == null || !result.ok) {
      return null;
    }

    Map<String, Object> transform =
        Helpers.toMapAny(Struct.getprop(ctx.point, "transform"));
    if (transform == null) {
      return null;
    }

    Object resform = Struct.getprop(transform, "res", null);
    if (resform == null) {
      return null;
    }

    Map<String, Object> data = new LinkedHashMap<>();
    data.put("ok", result.ok);
    data.put("status", result.status);
    data.put("statusText", result.statusText);
    data.put("headers", result.headers);
    data.put("body", result.body);
    data.put("err", result.err);
    data.put("resdata", result.resdata);
    data.put("resmatch", result.resmatch);

    Object resdata = Struct.transform(data, resform);

    result.resdata = resdata;
    return resdata;
  }
}
