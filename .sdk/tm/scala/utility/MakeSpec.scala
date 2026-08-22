package SCALAPACKAGE.utility

import java.util.{LinkedHashMap, List => JList, Map => JMap}
import SCALAPACKAGE.core._
import SCALAPACKAGE.utility.struct.Struct

object MakeSpec {
  def makeSpec(ctx: Context): Spec = {
    ctx.out.get("spec") match { case s: Spec => ctx.spec = s; return ctx.spec; case _ => }

    val point = ctx.point
    val options = ctx.options
    val utility = ctx.utility

    val base = Struct.getprop(options, "base")
    val prefix = Struct.getprop(options, "prefix")
    val suffix = Struct.getprop(options, "suffix")

    val parts = Struct.getprop(point, "parts")

    val specmap = new LinkedHashMap[String, Object]()
    specmap.put("base", base match { case s: String => s; case _ => "" })
    specmap.put("prefix", prefix match { case s: String => s; case _ => "" })
    parts match { case _: JList[_] => specmap.put("parts", parts); case _ => }
    specmap.put("suffix", suffix match { case s: String => s; case _ => "" })
    specmap.put("step", "start")
    ctx.spec = new Spec(specmap)

    ctx.spec.method = utility.prepareMethod(ctx)

    val allowMethod = Struct.getpath(options, java.util.List.of("allow", "method")) match { case s: String => s; case _ => "" }
    if (!allowMethod.contains(ctx.spec.method)) {
      throw ctx.makeError("spec_method_allow",
        "Method \"" + ctx.spec.method + "\" not allowed by SDK option allow.method value: \"" + allowMethod + "\"")
    }

    ctx.spec.params = utility.prepareParams(ctx)
    ctx.spec.query = utility.prepareQuery(ctx)
    ctx.spec.headers = utility.prepareHeaders(ctx)

    val pkind = Struct.getprop(ctx.point, "kind") match {
      case s: String => s
      case _ => ""
    }

    if ("graphql" == pkind) {
      // GraphQL addresses one endpoint: no path parts, no query string, and
      // the body carries the operation. prepareBody is skipped deliberately
      // — it only emits a body for data-input ops, whereas every GraphQL op
      // posts one, including load/list/remove.
      ctx.spec.body = utility.graphqlBody(ctx)
      ctx.spec.path = ""
      // prepareQuery already copied the op's match arguments into the query
      // string. Those same values are bound as operation variables, so
      // leaving them would send /graphql?id=i1.
      ctx.spec.query = new LinkedHashMap[String, Object]()
      ctx.spec.headers.put("content-type", Graphql.ContentType)
    } else {
      ctx.spec.body = utility.prepareBody(ctx)
      ctx.spec.path = utility.preparePath(ctx)
    }

    if (ctx.ctrl.explain != null) ctx.ctrl.explain.put("spec", ctx.spec)

    val spec = utility.prepareAuth(ctx)
    ctx.spec = spec
    spec
  }
}
