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

  private static final java.util.regex.Pattern PLACEHOLDER =
      java.util.regex.Pattern.compile("\\{[^{}/]+\\}");

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

    // A route the definition ends with a slash keeps it: a server such as a
    // Django REST one redirects or refuses the route without it.
    Object orig = ctx.point == null ? null : Struct.getprop(ctx.point, "orig", null);
    if (orig instanceof String && ((String) orig).endsWith("/") &&
        (spec.suffix == null || spec.suffix.isEmpty()) && !url.endsWith("/")) {
      url = url + "/";
    }

    Map<String, Object> resmatch = new LinkedHashMap<>();

    // Sent with the request, never recorded as the entity's match.
    List<String> authquery = spec.authquery == null ? List.of() : spec.authquery;

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

    // A placeholder left in the route would send the request to the wrong route.
    // The base's own placeholders are server variables, resolved with the options.
    String base = null == spec.base ? "" : spec.base.replaceAll("/+$", "");
    String route = url.startsWith(base) ? url.substring(base.length()) : url;
    List<String> unfilled = new ArrayList<>();
    java.util.regex.Matcher found = PLACEHOLDER.matcher(route);
    while (found.find()) {
      unfilled.add(found.group());
    }
    if (!unfilled.isEmpty()) {
      throw ctx.makeError("url_param_missing",
          "URL path has no value for " + String.join(", ", unfilled) + ".");
    }

    // Append query string from spec.query.
    String qsep = "?";
    for (List<Object> item : Struct.items(spec.query)) {
      String key = item.get(0) instanceof String ? (String) item.get(0) : "";
      Object val = item.get(1);
      if (val != null) {
        url += qsep + Struct.escurl(key) + "=" + Struct.escurl(Struct.stringify(val));
        qsep = "&";
        if (!authquery.contains(key)) {
          resmatch.put(key, val);
        }
      }
    }

    result.resmatch = resmatch;

    return url;
  }
}
