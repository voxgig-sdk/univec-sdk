package KOTLINPACKAGE.utility

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.Helpers
import KOTLINPACKAGE.utility.struct.Struct

// prepareAuth IS NOT HERE. It moved to utility/PrepareAuth.kt, which is
// GENERATED from the model rather than copied from tm/: where the credential
// goes (header, query parameter or cookie) and under what name are facts
// about the API, resolved by apidef into main.kit.info.security, and a
// template can only carry one answer. Hardcoding `authorization` here is
// exactly why an apiKey-in-query API got a header it does not read.
//
// It is still a top-level function in THIS package, so nothing changed for
// its callers: Register.kt still binds `u.prepareAuth = ::prepareAuth`.
// See src/cmp/kotlin/PrepareAuth_kotlin.ts.
//
// HEADER_AUTH, OPTION_APIKEY and NOT_FOUND went with it - they were
// file-private and nothing else in this file used them.

private val METHOD_MAP: Map<String, String> = mapOf(
  "create" to "POST",
  "update" to "PUT",
  "load" to "GET",
  "list" to "GET",
  "remove" to "DELETE",
  "patch" to "PATCH",
)

@Suppress("UNCHECKED_CAST")
fun param(ctx: Context, paramdef: Any?): Any? {
  val point = ctx.point
  val spec = ctx.spec
  val match = ctx.match
  val reqmatch = ctx.reqmatch
  val data = ctx.data
  val reqdata = ctx.reqdata

  val pt = Struct.typify(paramdef)

  val key: String
  if (0 < (Struct.T_STRING and pt)) {
    key = if (paramdef is String) paramdef else ""
  } else {
    val k = Struct.getprop(paramdef, "name")
    key = if (k is String) k else ""
  }

  var akey = ""
  if (point != null) {
    val alias = Helpers.toMapAny(Struct.getprop(point, "alias"))
    if (alias != null) {
      val ak = Struct.getprop(alias, key)
      if (ak is String) {
        akey = ak
      }
    }
  }

  var v = Struct.getprop(reqmatch, key, null)

  if (v == null) {
    v = Struct.getprop(match, key, null)
  }

  if (v == null && "" != akey) {
    if (spec != null) {
      spec.alias[akey] = key
    }
    v = Struct.getprop(reqmatch, akey, null)
  }

  if (v == null) {
    v = Struct.getprop(reqdata, key, null)
  }

  if (v == null) {
    v = Struct.getprop(data, key, null)
  }

  if (v == null && "" != akey) {
    v = Struct.getprop(reqdata, akey, null)
    if (v == null) {
      v = Struct.getprop(data, akey, null)
    }
  }

  return v
}

fun prepareBody(ctx: Context): Any? {
  if ("data" == ctx.op.input) {
    return ctx.utility!!.transformRequest(ctx)
  }
  return null
}

@Suppress("UNCHECKED_CAST")
fun prepareHeaders(ctx: Context): MutableMap<String, Any?> {
  val options = ctx.client!!.optionsMap()

  val headers = Struct.getprop(options, "headers", null)
  if (headers == null) {
    return linkedMapOf()
  }

  val out = Helpers.toMapAny(Struct.clone(headers))
  return out ?: linkedMapOf()
}

fun prepareMethod(ctx: Context): String? {
  val opname = ctx.op.name

  // The API definition is authoritative: a POST-only or PATCH-based API
  // exposes `update` as POST or PATCH, not the PUT the op name implies.
  // Only fall back to the op-name convention when the point has no method.
  val pm = Struct.getprop(ctx.point, "method")
  if (pm is String && "" != pm) {
    return pm.uppercase()
  }

  // No default: an op name outside the convention resolves to NO method,
  // exactly as the ts reference (`methodMap[key]` is undefined there).
  // The silent-pass engine hid a stray "GET" fallback here; the shared
  // corpus (prepareMethod, opname "bad" -> null) pins it now.
  return METHOD_MAP[opname]
}

@Suppress("UNCHECKED_CAST")
fun prepareParams(ctx: Context): MutableMap<String, Any?> {
  val utility = ctx.utility!!
  val point = ctx.point

  var params: MutableList<Any?>? = null
  val argsMap = Helpers.toMapAny(Struct.getprop(point, "args"))
  if (argsMap != null) {
    val p = Struct.getprop(argsMap, "params")
    if (p is MutableList<*>) {
      params = p as MutableList<Any?>
    }
  }
  if (params == null) {
    params = mutableListOf()
  }

  val out = linkedMapOf<String, Any?>()
  for (pd in params) {
    val v = utility.param(ctx, pd)
    if (v != null) {
      val pdm = Helpers.toMapAny(pd)
      if (pdm != null) {
        val name = Struct.getprop(pdm, "name")
        if (name is String && "" != name) {
          out[name] = v
        }
      }
    }
  }

  return out
}

@Suppress("UNCHECKED_CAST")
fun preparePath(ctx: Context): String {
  var parts: MutableList<Any?>? = null
  val p = Struct.getprop(ctx.point, "parts")
  if (p is MutableList<*>) {
    parts = p as MutableList<Any?>
  }
  if (parts == null) {
    parts = mutableListOf()
  }

  return Struct.join(parts, "/", true)
}

@Suppress("UNCHECKED_CAST")
fun prepareQuery(ctx: Context): MutableMap<String, Any?> {
  val point = ctx.point
  val reqmatch = ctx.reqmatch

  var params: MutableList<Any?>? = null
  if (point != null) {
    val p = Struct.getprop(point, "params")
    if (p is MutableList<*>) {
      params = p as MutableList<Any?>
    }
  }
  if (params == null) {
    params = mutableListOf()
  }

  val out = linkedMapOf<String, Any?>()
  for (item in Struct.items(reqmatch)) {
    val key = if (item[0] is String) item[0] as String else ""
    val v = item[1]
    if (v != null && "\$action" != key && !containsStr(params, key)) {
      out[key] = v
    }
  }

  return out
}

private fun containsStr(list: List<Any?>, s: String): Boolean {
  for (v in list) {
    if (v is String && v == s) {
      return true
    }
  }
  return false
}
