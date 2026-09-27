package JAVAPACKAGE.utility;

import java.util.LinkedHashMap;
import java.util.Map;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Helpers;
import JAVAPACKAGE.utility.struct.Struct;

final class TransformRequest {

  private TransformRequest() {}

  static Object transformRequest(Context ctx) {
    if (ctx.spec != null) {
      ctx.spec.step = "reqform";
    }

    Map<String, Object> transform =
        Helpers.toMapAny(Struct.getprop(ctx.point, "transform"));
    if (transform == null) {
      return stripAction(ctx.reqdata);
    }

    Object reqform = Struct.getprop(transform, "req", null);
    if (reqform == null) {
      return stripAction(ctx.reqdata);
    }

    Map<String, Object> data = new LinkedHashMap<>();
    data.put("reqdata", ctx.reqdata);

    return stripAction(Struct.transform(data, reqform));
  }

  // `$action` selects the point (see MakePoint); it is never an API field, so
  // the body is a copy without it. The caller's map is left untouched.
  private static Object stripAction(Object reqdata) {
    if (!(reqdata instanceof Map) || !((Map<?, ?>) reqdata).containsKey("$action")) {
      return reqdata;
    }
    Map<String, Object> body = new LinkedHashMap<>();
    for (Map.Entry<?, ?> e : ((Map<?, ?>) reqdata).entrySet()) {
      if (!"$action".equals(e.getKey())) {
        body.put(String.valueOf(e.getKey()), e.getValue());
      }
    }
    return body;
  }
}
