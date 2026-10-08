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

fun param(ctx: Context, paramdef: Any?): Any? {
  val pt = Struct.typify(paramdef)

  val key: String
  if (0 < (Struct.T_STRING and pt)) {
    key = if (paramdef is String) paramdef else ""
  } else {
    val k = Struct.getprop(paramdef, "name")
    key = if (k is String) k else ""
  }

  val akey = paramAlias(ctx.point, key)
  val spec = ctx.spec
  if (spec != null && "" != akey &&
    Struct.getprop(ctx.reqmatch, key, null) == null && Struct.getprop(ctx.match, key, null) == null
  ) {
    spec.alias[akey] = key
  }

  return paramValue(ctx, ctx.point, key)
}

// The name a point gives a parameter in the call, if it renames it.
private fun paramAlias(point: Map<String, Any?>?, key: String): String {
  if (point != null) {
    val alias = Helpers.toMapAny(Struct.getprop(point, "alias"))
    if (alias != null) {
      val ak = Struct.getprop(alias, key)
      if (ak is String) {
        return ak
      }
    }
  }
  return ""
}

// The value the call or its entity gives a point's parameter, under its name
// or the point's alias for it.
fun paramValue(ctx: Context, point: Map<String, Any?>?, key: String): Any? {
  val akey = paramAlias(point, key)

  var v = Struct.getprop(ctx.reqmatch, key, null)

  if (v == null) {
    v = Struct.getprop(ctx.match, key, null)
  }

  if (v == null && "" != akey) {
    v = Struct.getprop(ctx.reqmatch, akey, null)
  }

  if (v == null) {
    v = Struct.getprop(ctx.reqdata, key, null)
  }

  if (v == null) {
    v = Struct.getprop(ctx.data, key, null)
  }

  if (v == null && "" != akey) {
    v = Struct.getprop(ctx.reqdata, akey, null)
    if (v == null) {
      v = Struct.getprop(ctx.data, akey, null)
    }
  }

  return v
}

// One argument a point declares, with the name it travels under and the
// value the call passes for it.
internal data class CallArg(val name: String, val wire: String, val v: Any?)

// The arguments a point declares in one location, query or header, each with
// the name it travels under and the value this call passes in its match or
// else its data. Unlike a path parameter, the entity's stored match and data
// never supply one.
internal fun callArgs(ctx: Context, kind: String): List<CallArg> {
  val point = ctx.point ?: return emptyList()
  val defs = Struct.getpath(point, listOf("args", kind)) as? List<*> ?: return emptyList()
  val out = mutableListOf<CallArg>()
  for (ad in defs) {
    val name = Struct.getprop(ad, "name")
    if (name !is String || name.isEmpty()) {
      continue
    }
    val orig = Struct.getprop(ad, "orig")
    val wire = if (orig is String && orig.isNotEmpty()) orig else name
    val v = Struct.getprop(ctx.reqmatch, name, null) ?: Struct.getprop(ctx.reqdata, name, null)
    out.add(CallArg(name, wire, v))
  }
  return out
}

fun prepareBody(ctx: Context): Any? {
  if ("data" == ctx.op.input) {
    if (Media.isRawRequest(ctx.point)) {
      return Media.rawBody(ctx.reqdata)
    }
    return ctx.utility!!.transformRequest(ctx)
  }
  return null
}

@Suppress("UNCHECKED_CAST")
fun prepareHeaders(ctx: Context): MutableMap<String, Any?> {
  val options = ctx.client!!.optionsMap()

  val headers = Struct.getprop(options, "headers", null)
  val out: MutableMap<String, Any?> = Media.headers(ctx.point,
    (if (headers == null) null else Helpers.toMapAny(Struct.clone(headers))) ?: linkedMapOf())

  // A header argument replaces a default of the same name, whatever its case.
  for (arg in callArgs(ctx, "header")) {
    if (arg.v != null) {
      val key = arg.wire.lowercase()
      out.keys.removeAll { it.lowercase() == key }
      out[key] = Struct.stringify(arg.v)
    }
  }

  // A cookie argument travels in the cookie header, form serialized and
  // percent-encoded, replacing a cookie of the same name among those the
  // caller's headers already send.
  val sent = callArgs(ctx, "cookie").filter { it.v != null }
  if (sent.isNotEmpty()) {
    val names = sent.flatMap {
      if (it.v is Map<*, *>) Struct.keysof(it.v).map { key -> Struct.escurl(key) } else listOf(it.wire)
    }
    val kept = mutableListOf<String>()
    for (key in out.keys.filter { it.lowercase() == "cookie" }) {
      val given = out.remove(key)
      if (given is String) kept.addAll(cookieKeep(given, names))
    }
    for (arg in sent) {
      val pair = cookiePair(arg.wire, arg.v)
      if (pair.isNotEmpty()) kept.add(pair)
    }
    if (kept.isNotEmpty()) out["cookie"] = kept.joinToString("; ")
  }

  return out
}

// The form style of a cookie parameter: a list repeats the name, a map sends
// its own keys, and every value is percent-encoded.
private fun cookiePair(wire: String, v: Any?): String {
  val esc = { x: Any? -> Struct.escurl(Struct.stringify(x)) }
  val pairs = when (v) {
    is List<*> -> v.map { wire + "=" + esc(it) }
    is Map<*, *> -> Struct.keysof(v).map { Struct.escurl(it) + "=" + esc(Struct.getprop(v, it)) }
    else -> listOf(wire + "=" + esc(v))
  }
  return pairs.joinToString("; ")
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

  val params: MutableList<Any?> = mutableListOf()
  if (point != null) {
    val p = Struct.getprop(point, "params")
    if (p is MutableList<*>) {
      params.addAll(p as MutableList<Any?>)
    }
    // A path parameter travels in the path. The generated config lists them
    // as args.params, which prepareParams reads; params is the older list.
    val pl = Struct.getpath(point, listOf("args", "params"))
    if (pl is List<*>) {
      for (pd in pl) {
        val name = Struct.getprop(pd, "name")
        if (name is String) {
          params.add(name)
        }
      }
    }
    // A header or cookie parameter travels in the headers, which prepareHeaders
    // fills, unless a query parameter shares its name: then both are sent.
    val declared = (Struct.getpath(point, listOf("args", "query")) as? List<*>)
      ?.map { Struct.getprop(it, "name") } ?: emptyList()
    val located = listOf(Struct.getpath(point, listOf("args", "header")),
      Struct.getpath(point, listOf("args", "cookie")))
    for (hl in located) {
      if (hl is List<*>) {
        for (hd in hl) {
          val name = Struct.getprop(hd, "name")
          if (name is String && name !in declared) {
            params.add(name)
          }
        }
      }
    }
  }

  // A query parameter travels under the name the definition gives it, its
  // orig, which the model may have renamed for the caller.
  val wire = mutableMapOf<String, String>()
  if (point != null) {
    val ql = Struct.getpath(point, listOf("args", "query"))
    if (ql is List<*>) {
      for (qd in ql) {
        val name = Struct.getprop(qd, "name")
        val orig = Struct.getprop(qd, "orig")
        if (name is String && orig is String && orig.isNotEmpty()) {
          wire[name] = orig
        }
      }
    }
  }

  val out = linkedMapOf<String, Any?>()
  for (item in Struct.items(reqmatch)) {
    val key = if (item[0] is String) item[0] as String else ""
    val v = item[1]
    if (v != null && "\$action" != key && !containsStr(params, key)) {
      out[wire[key] ?: key] = v
    }
  }

  // A create or update passes its query arguments in its data.
  for (arg in callArgs(ctx, "query")) {
    if (arg.v != null && !containsStr(params, arg.name)) {
      out[arg.wire] = arg.v
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

// The caller's cookie pieces with the named cookies removed: a cookie is one
// ;-delimited piece, whatever its value holds.
internal fun cookieKeep(header: String, names: List<String>): MutableList<String> {
  val kept = mutableListOf<String>()
  for (piece in header.split(";")) {
    val cookie = piece.trim()
    if (cookie.isNotEmpty() && cookie.substringBefore("=").trim() !in names) kept.add(cookie)
  }
  return kept
}
