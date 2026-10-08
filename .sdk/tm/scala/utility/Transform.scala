package SCALAPACKAGE.utility

import java.util.{LinkedHashMap, Map => JMap}
import SCALAPACKAGE.core._
import SCALAPACKAGE.utility.struct.Struct

object TransformRequest {
  def transformRequest(ctx: Context): Object = {
    if (ctx.spec != null) ctx.spec.step = "reqform"

    val reqdata = omit(ctx.reqdata, routedArgNames(ctx))

    val transform = Helpers.toMapAny(Struct.getprop(ctx.point, "transform"))
    if (transform == null) return stripAction(reqdata)

    val reqform = Struct.getprop(transform, "req", null)
    if (reqform == null) return stripAction(reqdata)

    val data = new LinkedHashMap[String, Object]()
    data.put("reqdata", reqdata)

    stripAction(Struct.transform(data, reqform))
  }

  // `$action` selects the point (see MakePoint); it is never an API field, so
  // the body is a copy without it. The caller's map is left untouched.
  private def stripAction(reqdata: Object): Object = omit(reqdata, Seq("$action"))

  // A header, cookie or query argument travels where PrepareHeaders or
  // PrepareQuery sends it, so the body is built from the request data without
  // it, unless the point marks it as a field the body keeps.
  private def routedArgNames(ctx: Context): Seq[String] =
    (Param.callArgs(ctx, "header") ++ Param.callArgs(ctx, "cookie") ++ Param.callArgs(ctx, "query")).map(_._1)
      .filterNot(name => fieldArg(ctx, name))

  private def fieldArg(ctx: Context, name: String): Boolean =
    ctx.point != null && Seq("header", "cookie", "query").exists { kind =>
      Struct.getpath(ctx.point, java.util.List.of("args", kind)) match {
        case l: java.util.List[_] =>
          l.toArray.exists(ad => name == Struct.getprop(ad, "name") && java.lang.Boolean.TRUE == Struct.getprop(ad, "field"))
        case _ => false
      }
    }

  private def omit(reqdata: Object, names: Seq[String]): Object = {
    reqdata match {
      case src: JMap[_, _] if names.exists(n => src.containsKey(n)) =>
        val body = new LinkedHashMap[String, Object]()
        val it = src.asInstanceOf[JMap[String, Object]].entrySet().iterator()
        while (it.hasNext) {
          val e = it.next()
          if (!names.contains(e.getKey)) body.put(e.getKey, e.getValue)
        }
        body
      case _ => reqdata
    }
  }
}

object TransformResponse {
  def transformResponse(ctx: Context): Object = {
    val result = ctx.result

    if (ctx.spec != null) ctx.spec.step = "resform"

    if (result == null || !result.ok) return null

    val transform = Helpers.toMapAny(Struct.getprop(ctx.point, "transform"))
    if (transform == null) return null

    val resform = Struct.getprop(transform, "res", null)
    if (resform == null) return null

    val data = new LinkedHashMap[String, Object]()
    data.put("ok", java.lang.Boolean.valueOf(result.ok))
    data.put("status", java.lang.Integer.valueOf(result.status))
    data.put("statusText", result.statusText)
    data.put("headers", result.headers)
    data.put("body", result.body)
    data.put("err", result.err)
    data.put("resdata", result.resdata)
    data.put("resmatch", result.resmatch)

    val resdata = Struct.transform(data, resform)
    result.resdata = resdata
    resdata
  }
}
