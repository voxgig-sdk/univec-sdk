package JAVAPACKAGE.utility;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Spec;
import JAVAPACKAGE.core.Utility;
import JAVAPACKAGE.utility.struct.Struct;

@SuppressWarnings({"unchecked"})
final class MakeSpec {

  private MakeSpec() {}

  static Spec makeSpec(Context ctx) {
    Object outSpec = ctx.out.get("spec");
    if (outSpec instanceof Spec) {
      ctx.spec = (Spec) outSpec;
      return ctx.spec;
    }

    Map<String, Object> point = ctx.point;
    Map<String, Object> options = ctx.options;
    Utility utility = ctx.utility;

    Object base = Struct.getprop(options, "base");
    Object prefix = Struct.getprop(options, "prefix");
    Object suffix = Struct.getprop(options, "suffix");

    Object parts = Struct.getprop(point, "parts");

    Map<String, Object> specmap = new LinkedHashMap<>();
    specmap.put("base", base instanceof String ? base : "");
    specmap.put("prefix", prefix instanceof String ? prefix : "");
    if (parts instanceof List) {
      specmap.put("parts", parts);
    }
    specmap.put("suffix", suffix instanceof String ? suffix : "");
    specmap.put("step", "start");
    ctx.spec = new Spec(specmap);

    ctx.spec.method = utility.prepareMethod.apply(ctx);

    Object allowMethodRaw = Struct.getpath(options, List.of("allow", "method"));
    String allowMethod = allowMethodRaw instanceof String ? (String) allowMethodRaw : "";
    if (!allowMethod.contains(ctx.spec.method)) {
      throw ctx.makeError("spec_method_allow",
          "Method \"" + ctx.spec.method
              + "\" not allowed by SDK option allow.method value: \"" + allowMethod + "\"");
    }

    ctx.spec.params = utility.prepareParams.apply(ctx);
    ctx.spec.query = utility.prepareQuery.apply(ctx);
    ctx.spec.headers = utility.prepareHeaders.apply(ctx);

    if ("graphql".equals(Struct.getprop(point, "kind", null))) {
      // GraphQL addresses one endpoint: no path parts, no query string, and
      // the body carries the operation. prepareBody is skipped deliberately
      // — it only emits a body for data-input ops, whereas every GraphQL op
      // posts one, including load/list/remove.
      ctx.spec.body = utility.graphqlBody.apply(ctx);
      ctx.spec.path = "";
      // prepareQuery already copied the op's match arguments into the query
      // string. Those same values are bound as operation variables, so
      // leaving them would send /graphql?id=i1.
      ctx.spec.query = new LinkedHashMap<>();
      ctx.spec.headers.put("content-type", Graphql.GRAPHQL_CONTENT_TYPE);
    } else {
      ctx.spec.body = utility.prepareBody.apply(ctx);
      ctx.spec.path = utility.preparePath.apply(ctx);
    }

    if (ctx.ctrl.explain != null) {
      ctx.ctrl.explain.put("spec", ctx.spec);
    }

    Spec spec = utility.prepareAuth.apply(ctx);

    ctx.spec = spec;
    return spec;
  }
}
