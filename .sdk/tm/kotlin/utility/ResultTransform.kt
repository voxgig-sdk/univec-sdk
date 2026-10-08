package KOTLINPACKAGE.utility

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.Helpers
import KOTLINPACKAGE.utility.struct.Struct

fun resultBasic(ctx: Context): KOTLINPACKAGE.core.Result {
  val response = ctx.response
  val result = ctx.result

  if (result != null && response != null) {
    result.status = response.status
    result.statusText = response.statusText

    if (result.status >= 400) {
      val msg = "request: " + result.status + ": " + result.statusText
      val existing = result.err
      if (existing != null) {
        val prevmsg = existing.message
        result.err = ctx.makeError("request_status", "$prevmsg: $msg")
      } else {
        result.err = ctx.makeError("request_status", msg)
      }
    } else if (response.err != null) {
      result.err = response.err
    }
  }

  return result!!
}

fun resultBody(ctx: Context): KOTLINPACKAGE.core.Result {
  val response = ctx.response
  val result = ctx.result

  if (result != null) {
    if (response != null && response.jsonFunc != null && response.body != null) {
      result.body = response.jsonFunc!!.get()
    }
    if (response != null && response.unreadable) {
      result.err = KOTLINPACKAGE.core.Response.unreadableBody(ctx, result.status, result.headers,
        response.body, ctx.spec?.headers, result.err)
    }
  }

  return result!!
}

fun resultHeaders(ctx: Context): KOTLINPACKAGE.core.Result {
  val response = ctx.response
  val result = ctx.result

  if (result != null) {
    if (response != null && response.headers != null) {
      val hm = Helpers.toMapAny(response.headers)
      result.headers = hm ?: linkedMapOf()
    } else {
      result.headers = linkedMapOf()
    }
  }

  return result!!
}

// `$action` selects the point (see makePoint); it is never an API field, so
// the body is a copy without it. The caller's map is left untouched.
private fun stripAction(reqdata: Any?): Any? = omitKeys(reqdata, listOf("\$action"))

// A header, cookie or query argument travels where prepareHeaders or
// prepareQuery sends it, so the body is built from the request data without
// it, unless the point marks it as a field the body keeps.
private fun routedArgNames(ctx: Context): List<String> =
  (callArgs(ctx, "header") + callArgs(ctx, "cookie") + callArgs(ctx, "query")).map { it.name }
    .filter { !fieldArg(ctx, it) }

private fun fieldArg(ctx: Context, name: String): Boolean {
  val point = ctx.point ?: return false
  return listOf("header", "cookie", "query").any { kind ->
    val defs = Struct.getpath(point, listOf("args", kind)) as? List<*> ?: emptyList<Any?>()
    defs.any { name == Struct.getprop(it, "name") && true == Struct.getprop(it, "field") }
  }
}

private fun omitKeys(reqdata: Any?, names: List<String>): Any? {
  if (reqdata !is Map<*, *> || names.none { reqdata.containsKey(it) }) {
    return reqdata
  }
  val body = linkedMapOf<String, Any?>()
  for ((k, v) in reqdata) {
    if (k.toString() !in names) {
      body[k.toString()] = v
    }
  }
  return body
}

fun transformRequest(ctx: Context): Any? {
  if (ctx.spec != null) {
    ctx.spec!!.step = "reqform"
  }

  val reqdata = omitKeys(ctx.reqdata, routedArgNames(ctx))

  val transform = Helpers.toMapAny(Struct.getprop(ctx.point, "transform"))
    ?: return stripAction(reqdata)

  val reqform = Struct.getprop(transform, "req", null)
    ?: return stripAction(reqdata)

  val data = linkedMapOf<String, Any?>()
  data["reqdata"] = reqdata

  return stripAction(Struct.transform(data, reqform))
}

fun transformResponse(ctx: Context): Any? {
  val result = ctx.result

  if (ctx.spec != null) {
    ctx.spec!!.step = "resform"
  }

  if (result == null || !result.ok) {
    return null
  }

  val transform = Helpers.toMapAny(Struct.getprop(ctx.point, "transform"))
    ?: return null

  val resform = Struct.getprop(transform, "res", null)
    ?: return null

  val data = linkedMapOf<String, Any?>()
  data["ok"] = result.ok
  data["status"] = result.status
  data["statusText"] = result.statusText
  data["headers"] = result.headers
  data["body"] = result.body
  data["err"] = result.err
  data["resdata"] = result.resdata
  data["resmatch"] = result.resmatch

  val resdata = Struct.transform(data, resform)

  result.resdata = resdata
  return resdata
}
