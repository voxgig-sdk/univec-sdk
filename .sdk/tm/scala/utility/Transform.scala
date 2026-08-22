package SCALAPACKAGE.utility

import java.util.{LinkedHashMap, Map => JMap}
import SCALAPACKAGE.core._
import SCALAPACKAGE.utility.struct.Struct

object TransformRequest {
  def transformRequest(ctx: Context): Object = {
    if (ctx.spec != null) ctx.spec.step = "reqform"

    val transform = Helpers.toMapAny(Struct.getprop(ctx.point, "transform"))
    if (transform == null) return ctx.reqdata

    val reqform = Struct.getprop(transform, "req", null)
    if (reqform == null) return ctx.reqdata

    val data = new LinkedHashMap[String, Object]()
    data.put("reqdata", ctx.reqdata)

    Struct.transform(data, reqform)
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
