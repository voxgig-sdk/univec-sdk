package KOTLINPACKAGE.utility

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.Result
import KOTLINPACKAGE.core.Spec
import KOTLINPACKAGE.utility.struct.Struct

@Suppress("UNCHECKED_CAST")
fun makeSpec(ctx: Context): Spec {
  val outSpec = ctx.out["spec"]
  if (outSpec is Spec) {
    ctx.spec = outSpec
    return outSpec
  }

  val point = ctx.point
  val options = ctx.options
  val utility = ctx.utility!!

  val base = Struct.getprop(options, "base")
  val prefix = Struct.getprop(options, "prefix")
  val suffix = Struct.getprop(options, "suffix")

  val parts = Struct.getprop(point, "parts")

  val specmap = linkedMapOf<String, Any?>()
  specmap["base"] = if (base is String) base else ""
  specmap["prefix"] = if (prefix is String) prefix else ""
  if (parts is List<*>) {
    specmap["parts"] = parts
  }
  specmap["suffix"] = if (suffix is String) suffix else ""
  specmap["step"] = "start"
  val spec = Spec(specmap)
  ctx.spec = spec

  spec.method = utility.prepareMethod(ctx)

  val allowMethodRaw = Struct.getpath(options, listOf("allow", "method"))
  val allowMethod = if (allowMethodRaw is String) allowMethodRaw else ""
  if (!allowMethod.contains(spec.method)) {
    throw ctx.makeError(
      "spec_method_allow",
      "Method \"" + spec.method +
        "\" not allowed by SDK option allow.method value: \"" + allowMethod + "\"",
    )
  }

  spec.params = utility.prepareParams(ctx)
  spec.query = utility.prepareQuery(ctx)
  spec.headers = utility.prepareHeaders(ctx)

  if ("graphql" == Struct.getprop(ctx.point, "kind") as? String) {
    // GraphQL addresses one endpoint: no path parts, no query string, and
    // the body carries the operation. prepareBody is skipped deliberately
    // — it only emits a body for data-input ops, whereas every GraphQL op
    // posts one, including load/list/remove.
    spec.body = utility.graphqlBody(ctx)
    spec.path = ""
    // prepareQuery already copied the op's match arguments into the query
    // string. Those same values are bound as operation variables, so
    // leaving them would send /graphql?id=i1.
    spec.query = mutableMapOf()
    spec.headers["content-type"] = GRAPHQL_CONTENT_TYPE
  } else {
    spec.body = utility.prepareBody(ctx)
    spec.path = utility.preparePath(ctx)
  }

  if (ctx.ctrl.explain != null) {
    ctx.ctrl.explain!!["spec"] = spec
  }

  val authed = utility.prepareAuth(ctx)

  ctx.spec = authed
  return authed
}

fun makeUrl(ctx: Context): String {
  val spec = ctx.spec
  val result = ctx.result

  if (spec == null) {
    throw ctx.makeError("url_no_spec", "Expected context spec property to be defined.")
  }
  if (result == null) {
    throw ctx.makeError("url_no_result", "Expected context result property to be defined.")
  }

  val joinParts = mutableListOf<Any?>()
  joinParts.add(spec.base)
  joinParts.add(spec.prefix)
  joinParts.add(spec.path)
  joinParts.add(spec.suffix)
  var url = Struct.join(joinParts, "/", true)

  val resmatch = linkedMapOf<String, Any?>()

  val params = spec.params
  for (item in Struct.items(params)) {
    val key = if (item[0] is String) item[0] as String else ""
    val v = item[1]
    if (v != null) {
      val replacement = Struct.escurl(Struct.stringify(v))
      url = Regex("\\{" + Struct.escre(key) + "\\}").replace(url) { replacement }
      resmatch[key] = v
    }
  }

  // Append query string from spec.query.
  var qsep = "?"
  for (item in Struct.items(spec.query)) {
    val key = if (item[0] is String) item[0] as String else ""
    val v = item[1]
    if (v != null) {
      url += qsep + Struct.escurl(key) + "=" + Struct.escurl(Struct.stringify(v))
      qsep = "&"
      resmatch[key] = v
    }
  }

  result.resmatch = resmatch

  return url
}

fun makeFetchDef(ctx: Context): MutableMap<String, Any?> {
  val spec = ctx.spec
    ?: throw ctx.makeError("fetchdef_no_spec", "Expected context spec property to be defined.")

  if (ctx.result == null) {
    ctx.result = Result(linkedMapOf())
  }

  spec.step = "prepare"

  val url = ctx.utility!!.makeUrl(ctx)

  spec.url = url

  val fetchdef = linkedMapOf<String, Any?>()
  fetchdef["url"] = url
  fetchdef["method"] = spec.method
  fetchdef["headers"] = spec.headers

  val body = spec.body
  if (body != null) {
    if (body is MutableMap<*, *>) {
      fetchdef["body"] = Struct.jsonify(body)
    } else {
      fetchdef["body"] = body
    }
  }

  return fetchdef
}
