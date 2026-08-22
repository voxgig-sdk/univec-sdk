package JAVAPACKAGE.utility;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Result;
import JAVAPACKAGE.core.Spec;
import JAVAPACKAGE.utility.struct.Struct;

final class MakeUrl {

  private MakeUrl() {}

  static String makeUrl(Context ctx) {
    Spec spec = ctx.spec;
    Result result = ctx.result;

    if (spec == null) {
      throw ctx.makeError("url_no_spec",
          "Expected context spec property to be defined.");
    }
    if (result == null) {
      throw ctx.makeError("url_no_result",
          "Expected context result property to be defined.");
    }

    List<Object> joinParts = new ArrayList<>();
    joinParts.add(spec.base);
    joinParts.add(spec.prefix);
    joinParts.add(spec.path);
    joinParts.add(spec.suffix);
    String url = Struct.join(joinParts, "/", true);

    Map<String, Object> resmatch = new LinkedHashMap<>();

    Map<String, Object> params = spec.params;
    for (List<Object> item : Struct.items(params)) {
      String key = item.get(0) instanceof String ? (String) item.get(0) : "";
      Object val = item.get(1);
      if (val != null) {
        url = url.replaceAll("\\{" + Struct.escre(key) + "\\}",
            java.util.regex.Matcher.quoteReplacement(
                Struct.escurl(Struct.stringify(val))));
        resmatch.put(key, val);
      }
    }

    // Append query string from spec.query.
    String qsep = "?";
    for (List<Object> item : Struct.items(spec.query)) {
      String key = item.get(0) instanceof String ? (String) item.get(0) : "";
      Object val = item.get(1);
      if (val != null) {
        url += qsep + Struct.escurl(key) + "=" + Struct.escurl(Struct.stringify(val));
        qsep = "&";
        resmatch.put(key, val);
      }
    }

    result.resmatch = resmatch;

    return url;
  }
}
