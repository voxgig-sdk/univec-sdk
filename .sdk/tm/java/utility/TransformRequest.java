package JAVAPACKAGE.utility;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
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

    Object reqdata = omit(ctx.reqdata, routedArgNames(ctx));

    Map<String, Object> transform =
        Helpers.toMapAny(Struct.getprop(ctx.point, "transform"));
    if (transform == null) {
      return stripAction(reqdata);
    }

    Object reqform = Struct.getprop(transform, "req", null);
    if (reqform == null) {
      return stripAction(reqdata);
    }

    Map<String, Object> data = new LinkedHashMap<>();
    data.put("reqdata", reqdata);

    return stripAction(Struct.transform(data, reqform));
  }

  // `$action` selects the point (see MakePoint); it is never an API field, so
  // the body is a copy without it. The caller's map is left untouched.
  private static Object stripAction(Object reqdata) {
    return omit(reqdata, List.of("$action"));
  }

  // A header, cookie or query argument travels where PrepareHeaders or
  // PrepareQuery sends it, so the body is built from the request data without
  // it, unless the point marks it as a field the body keeps.
  private static List<String> routedArgNames(Context ctx) {
    List<String> names = new ArrayList<>();
    for (String kind : List.of("header", "cookie", "query")) {
      for (Param.CallArg arg : Param.callArgs(ctx, kind)) {
        if (!fieldArg(ctx, arg.name())) {
          names.add(arg.name());
        }
      }
    }
    return names;
  }

  private static boolean fieldArg(Context ctx, String name) {
    for (String kind : List.of("header", "cookie", "query")) {
      Object defs = ctx.point == null ? null : Struct.getpath(ctx.point, List.of("args", kind));
      if (defs instanceof List) {
        for (Object ad : (List<?>) defs) {
          if (name.equals(Struct.getprop(ad, "name", null)) &&
              Boolean.TRUE.equals(Struct.getprop(ad, "field", null))) {
            return true;
          }
        }
      }
    }
    return false;
  }

  private static Object omit(Object reqdata, List<String> names) {
    if (!(reqdata instanceof Map) || names.stream().noneMatch(((Map<?, ?>) reqdata)::containsKey)) {
      return reqdata;
    }
    Map<String, Object> body = new LinkedHashMap<>();
    for (Map.Entry<?, ?> e : ((Map<?, ?>) reqdata).entrySet()) {
      if (!names.contains(e.getKey())) {
        body.put(String.valueOf(e.getKey()), e.getValue());
      }
    }
    return body;
  }
}
