package JAVAPACKAGE.utility;

import java.util.LinkedHashMap;
import java.util.Map;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Result;
import JAVAPACKAGE.core.Spec;

final class MakeFetchDef {

  private MakeFetchDef() {}

  static Map<String, Object> makeFetchDef(Context ctx) {
    Spec spec = ctx.spec;
    if (spec == null) {
      throw ctx.makeError("fetchdef_no_spec",
          "Expected context spec property to be defined.");
    }

    if (ctx.result == null) {
      ctx.result = new Result(new LinkedHashMap<>());
    }

    spec.step = "prepare";

    String url = ctx.utility.makeUrl.apply(ctx);

    spec.url = url;

    Map<String, Object> fetchdef = new LinkedHashMap<>();
    fetchdef.put("url", url);
    fetchdef.put("method", spec.method);
    fetchdef.put("headers", spec.headers);

    if (spec.body != null) {
      fetchdef.put("body", Media.requestBody(ctx.point, spec.body));
    }

    return fetchdef;
  }
}
