package SCALAPACKAGE.core

import java.util.{ArrayList, LinkedHashMap, List => JList, Map => JMap}
import java.util.concurrent.ThreadLocalRandom
import SCALAPACKAGE.utility.struct.Struct

// Per-operation context threaded through the pipeline and feature hooks.
class Context(ctxmap: JMap[String, Object], basectx: Context) {

  var id: String = "C" + (ThreadLocalRandom.current().nextInt(90000000) + 10000000)
  var out: JMap[String, Object] = new LinkedHashMap[String, Object]()
  var ctrl: Control = new Control()
  var meta: JMap[String, Object] = new LinkedHashMap[String, Object]()
  var client: SdkClient = null
  var utility: Utility = null
  var op: Operation = null
  var point: JMap[String, Object] = null
  var config: JMap[String, Object] = null
  var entopts: JMap[String, Object] = null
  var options: JMap[String, Object] = null
  var opmap: JMap[String, Operation] = null
  var response: Response = null
  var result: Result = null
  var spec: Spec = null
  var data: JMap[String, Object] = null
  var reqdata: JMap[String, Object] = null
  var matchData: JMap[String, Object] = null
  var reqmatch: JMap[String, Object] = null
  var entity: Entity = null
  var shared: JMap[String, Object] = null

  locally {
    // Client
    Helpers.getCtxProp(ctxmap, "client") match { case c: SdkClient => client = c; case _ => }
    if (client == null && basectx != null) client = basectx.client

    // Utility
    Helpers.getCtxProp(ctxmap, "utility") match { case u: Utility => utility = u; case _ => }
    if (utility == null && basectx != null) utility = basectx.utility

    // Ctrl
    val cv = Helpers.getCtxProp(ctxmap, "ctrl")
    if (cv != null) {
      cv match {
        case cm: JMap[_, _] =>
          val m = cm.asInstanceOf[JMap[String, Object]]
          m.get("throw") match { case t: java.lang.Boolean => ctrl.throwing = t; case _ => }
          m.get("explain") match { case e: JMap[_, _] => ctrl.explain = e.asInstanceOf[JMap[String, Object]]; case _ => }
          m.get("actor") match { case a: String => ctrl.actor = a; case _ => }
          m.get("paging") match { case p: JMap[_, _] => ctrl.paging = p.asInstanceOf[JMap[String, Object]]; case _ => }
        case c: Control => ctrl = c
        case _ =>
      }
    } else if (basectx != null && basectx.ctrl != null) {
      ctrl = basectx.ctrl
    }

    // Meta
    Helpers.getCtxProp(ctxmap, "meta") match {
      case m: JMap[_, _] => meta = m.asInstanceOf[JMap[String, Object]]
      case _ => if (basectx != null && basectx.meta != null) meta = basectx.meta
    }

    // Config
    Helpers.getCtxProp(ctxmap, "config") match { case cfg: JMap[_, _] => config = cfg.asInstanceOf[JMap[String, Object]]; case _ => }
    if (config == null && basectx != null) config = basectx.config

    // Entopts
    Helpers.getCtxProp(ctxmap, "entopts") match { case eo: JMap[_, _] => entopts = eo.asInstanceOf[JMap[String, Object]]; case _ => }
    if (entopts == null && basectx != null) entopts = basectx.entopts

    // Options
    Helpers.getCtxProp(ctxmap, "options") match { case o: JMap[_, _] => options = o.asInstanceOf[JMap[String, Object]]; case _ => }
    if (options == null && basectx != null) options = basectx.options

    // Entity
    Helpers.getCtxProp(ctxmap, "entity") match { case e: Entity => entity = e; case _ => }
    if (entity == null && basectx != null) entity = basectx.entity

    // Shared
    Helpers.getCtxProp(ctxmap, "shared") match { case s: JMap[_, _] => shared = s.asInstanceOf[JMap[String, Object]]; case _ => }
    if (shared == null && basectx != null) shared = basectx.shared

    // Opmap
    Helpers.getCtxProp(ctxmap, "opmap") match { case om: JMap[_, _] => opmap = om.asInstanceOf[JMap[String, Operation]]; case _ => }
    if (opmap == null && basectx != null) opmap = basectx.opmap
    if (opmap == null) opmap = new LinkedHashMap[String, Operation]()

    // Data
    data = Helpers.toMapAny(Helpers.getCtxProp(ctxmap, "data"))
    if (data == null) data = new LinkedHashMap[String, Object]()
    reqdata = Helpers.toMapAny(Helpers.getCtxProp(ctxmap, "reqdata"))
    if (reqdata == null) reqdata = new LinkedHashMap[String, Object]()
    matchData = Helpers.toMapAny(Helpers.getCtxProp(ctxmap, "match"))
    if (matchData == null) matchData = new LinkedHashMap[String, Object]()
    reqmatch = Helpers.toMapAny(Helpers.getCtxProp(ctxmap, "reqmatch"))
    if (reqmatch == null) reqmatch = new LinkedHashMap[String, Object]()

    // Point
    Helpers.getCtxProp(ctxmap, "point") match { case t: JMap[_, _] => point = t.asInstanceOf[JMap[String, Object]]; case _ => }
    if (point == null && basectx != null) point = basectx.point

    // Spec
    Helpers.getCtxProp(ctxmap, "spec") match { case sp: Spec => spec = sp; case _ => }
    if (spec == null && basectx != null) spec = basectx.spec

    // Result
    Helpers.getCtxProp(ctxmap, "result") match { case r: Result => result = r; case _ => }
    if (result == null && basectx != null) result = basectx.result

    // Response
    Helpers.getCtxProp(ctxmap, "response") match { case resp: Response => response = resp; case _ => }
    if (response == null && basectx != null) response = basectx.response

    // Resolve operation
    val opname = Helpers.getCtxProp(ctxmap, "opname") match { case s: String => s; case _ => "" }
    op = resolveOp(opname)
  }

  private def resolveOp(opname: String): Operation = {
    // Cache key is `<entity>:<opname>` so two entities with the same op get
    // distinct cached Operations.
    var entname = ""
    if (entity != null) entname = entity.getName()
    val cacheKey = entname + ":" + opname

    val cached = opmap.get(cacheKey)
    if (cached != null) return cached

    if ("" == opname) return new Operation(new LinkedHashMap[String, Object]())

    val opcfg = Struct.getpath(config, java.util.List.of("entity", entname, "op", opname))

    var input = "match"
    if ("update" == opname || "create" == opname) input = "data"

    var points: JList[Object] = null
    opcfg match {
      case _: JMap[_, _] =>
        Struct.getprop(opcfg, "points") match {
          case t: JList[_] => points = t.asInstanceOf[JList[Object]]
          case _ =>
        }
      case _ =>
    }
    if (points == null) points = new ArrayList[Object]()

    val opdef = new LinkedHashMap[String, Object]()
    opdef.put("entity", entname)
    opdef.put("name", opname)
    opdef.put("input", input)
    opdef.put("points", points)

    val newop = new Operation(opdef)
    opmap.put(cacheKey, newop)
    newop
  }

  def makeError(code: String, msg: String): SdkError = new SdkError(code, msg, this)
}
