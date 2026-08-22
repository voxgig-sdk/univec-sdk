package SCALAPACKAGE.utility

import java.util.{Map => JMap}
import SCALAPACKAGE.core._
import SCALAPACKAGE.utility.struct.Struct

object MakeContext {
  def makeContext(ctxmap: JMap[String, Object], basectx: Context): Context =
    new Context(ctxmap, basectx)
}

object Clean {
  def clean(ctx: Context, v: Object): Object = v
}

object Done {
  def done(ctx: Context): Object = {
    if (ctx.ctrl.explain != null) {
      ctx.ctrl.explain = Clean.clean(ctx, ctx.ctrl.explain).asInstanceOf[JMap[String, Object]]
      val explainResult = ctx.ctrl.explain.get("result")
      val rm = Helpers.toMapAny(explainResult)
      if (rm != null) rm.remove("err")
    }

    if (ctx.result != null && ctx.result.ok) return ctx.result.resdata

    MakeError.makeError(ctx, null)
  }
}

object Param {
  def param(ctx: Context, paramdef: Object): Object = {
    val point = ctx.point
    val spec = ctx.spec
    val matchData = ctx.matchData
    val reqmatch = ctx.reqmatch
    val data = ctx.data
    val reqdata = ctx.reqdata

    val pt = Struct.typify(paramdef)

    val key: String =
      if (0 < (Struct.T_string & pt)) paramdef match { case s: String => s; case _ => "" }
      else Struct.getprop(paramdef, "name") match { case s: String => s; case _ => "" }

    var akey = ""
    if (point != null) {
      val alias = Helpers.toMapAny(Struct.getprop(point, "alias"))
      if (alias != null) {
        Struct.getprop(alias, key) match { case ak: String => akey = ak; case _ => }
      }
    }

    var v = Struct.getprop(reqmatch, key, null)
    if (v == null) v = Struct.getprop(matchData, key, null)
    if (v == null && "" != akey) {
      if (spec != null) spec.alias.put(akey, key)
      v = Struct.getprop(reqmatch, akey, null)
    }
    if (v == null) v = Struct.getprop(reqdata, key, null)
    if (v == null) v = Struct.getprop(data, key, null)
    if (v == null && "" != akey) {
      v = Struct.getprop(reqdata, akey, null)
      if (v == null) v = Struct.getprop(data, akey, null)
    }
    v
  }
}
