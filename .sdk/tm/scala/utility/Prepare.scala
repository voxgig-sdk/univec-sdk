package SCALAPACKAGE.utility

import java.util.{ArrayList, LinkedHashMap, List => JList, Map => JMap}
import SCALAPACKAGE.core._
import SCALAPACKAGE.utility.struct.Struct

object PreparePath {
  def preparePath(ctx: Context): String = {
    var parts: JList[Object] = null
    Struct.getprop(ctx.point, "parts") match { case l: JList[_] => parts = l.asInstanceOf[JList[Object]]; case _ => }
    if (parts == null) parts = new ArrayList[Object]()
    Struct.join(parts, "/", true)
  }
}

object PrepareMethod {
  // The API definition is authoritative: a POST-only or PATCH-based API
  // exposes `update` as POST or PATCH, not the PUT the op name implies.
  // Only fall back to the op-name convention when the point has no method.
  def prepareMethod(ctx: Context): String = Struct.getprop(ctx.point, "method") match {
    case s: String if s.nonEmpty => s.toUpperCase
    case _ => ctx.op.name match {
      case "create" => "POST"
      case "update" => "PUT"
      case "load" => "GET"
      case "list" => "GET"
      case "remove" => "DELETE"
      case "patch" => "PATCH"
      // No GET catch-all: an unrecognised op must fall through to the
      // allow.method gate, not be silently issued as a GET.
      case _ => ""
    }
  }
}

object PrepareParams {
  def prepareParams(ctx: Context): JMap[String, Object] = {
    val utility = ctx.utility
    val point = ctx.point

    var params: JList[Object] = null
    val argsMap = Helpers.toMapAny(Struct.getprop(point, "args"))
    if (argsMap != null) {
      Struct.getprop(argsMap, "params") match { case l: JList[_] => params = l.asInstanceOf[JList[Object]]; case _ => }
    }
    if (params == null) params = new ArrayList[Object]()

    val out = new LinkedHashMap[String, Object]()
    val it = params.iterator()
    while (it.hasNext) {
      val pd = it.next()
      val v = utility.param(ctx, pd)
      if (v != null) {
        val pdm = Helpers.toMapAny(pd)
        if (pdm != null) {
          Struct.getprop(pdm, "name") match { case name: String if name != "" => out.put(name, v); case _ => }
        }
      }
    }
    out
  }
}

object PrepareQuery {
  def prepareQuery(ctx: Context): JMap[String, Object] = {
    val point = ctx.point
    var reqmatch = ctx.reqmatch
    if (reqmatch == null) reqmatch = new LinkedHashMap[String, Object]()

    var params: JList[Object] = null
    if (point != null) {
      Struct.getprop(point, "params") match { case l: JList[_] => params = l.asInstanceOf[JList[Object]]; case _ => }
    }
    if (params == null) params = new ArrayList[Object]()

    val out = new LinkedHashMap[String, Object]()
    val it = Struct.items(reqmatch).iterator()
    while (it.hasNext) {
      val item = it.next()
      val key = item.get(0) match { case s: String => s; case _ => "" }
      val v = item.get(1)
      if (v != null && !containsStr(params, key)) out.put(key, v)
    }
    out
  }

  private def containsStr(list: JList[Object], s: String): Boolean = {
    val it = list.iterator()
    while (it.hasNext) {
      it.next() match { case v: String if v == s => return true; case _ => }
    }
    false
  }
}

object PrepareHeaders {
  def prepareHeaders(ctx: Context): JMap[String, Object] = {
    val options = ctx.client.optionsMap()
    val headers = Struct.getprop(options, "headers")
    if (headers == null) return new LinkedHashMap[String, Object]()
    val out = Helpers.toMapAny(Struct.clone(headers))
    if (out != null) out else new LinkedHashMap[String, Object]()
  }
}

object PrepareBody {
  def prepareBody(ctx: Context): Object =
    if ("data" == ctx.op.input) ctx.utility.transformRequest(ctx) else null
}

object PrepareAuth {
  val HEADER_AUTH = "authorization"
  val OPTION_APIKEY = "apikey"
  val NOT_FOUND = "__NOTFOUND__"

  def prepareAuth(ctx: Context): Spec = {
    val spec = ctx.spec
    if (spec == null) throw ctx.makeError("auth_no_spec", "Expected context spec property to be defined.")

    val headers = spec.headers
    val options = ctx.client.optionsMap()

    // Public APIs that need no auth omit the options.auth block entirely.
    if (options.get("auth") == null) {
      headers.remove(HEADER_AUTH)
      return spec
    }

    val apikey = Struct.getprop(options, OPTION_APIKEY, NOT_FOUND)

    var skip = false
    if (apikey == null) skip = true
    else apikey match {
      case s: String if NOT_FOUND == s || "" == s => skip = true
      case _ =>
    }

    if (skip) {
      headers.remove(HEADER_AUTH)
    } else {
      var authPrefix = ""
      Struct.getpath(options, java.util.List.of("auth", "prefix")) match { case s: String => authPrefix = s; case _ => }
      val apikeyVal = apikey match { case s: String => s; case _ => "" }
      if ("" == authPrefix) headers.put(HEADER_AUTH, apikeyVal)
      else headers.put(HEADER_AUTH, authPrefix + " " + apikeyVal)
    }

    spec
  }
}
