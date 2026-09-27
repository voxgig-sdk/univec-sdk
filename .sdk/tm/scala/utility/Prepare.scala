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
      if (v != null && "$action" != key && !containsStr(params, key)) out.put(key, v)
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

// NO `object PrepareAuth` HERE, and its absence is the point.
//
// WHERE the credential goes is a fact about the API - header, query or
// cookie, under the name the spec gives - and apidef resolves all of it
// into main.kit.info.security. This file can hold only ONE answer, so the
// object that used to sit here hardcoded `val HEADER_AUTH = "authorization"`
// and an apiKey-in-query API (joplin's `?token=`) got a header it ignores.
//
// So prepareAuth is GENERATED, into utility/PrepareAuth.scala beside this
// file, by src/cmp/scala/PrepareAuth_scala.ts - which emits the one branch
// this API actually uses. It stays `object PrepareAuth` in this same
// package, so utility/Register.scala's `u.prepareAuth = (ctx) =>
// PrepareAuth.prepareAuth(ctx)` binds it with no change: scala resolves the
// object by package, not by file name.
//
// The six objects above are placement-independent and stay templated.
