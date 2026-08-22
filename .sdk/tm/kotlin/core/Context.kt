package KOTLINPACKAGE.core

import java.util.concurrent.ThreadLocalRandom

import KOTLINPACKAGE.utility.struct.Struct

/** Per-operation context threaded through the pipeline and feature hooks. */
@Suppress("UNCHECKED_CAST")
class Context(ctxmap: MutableMap<String, Any?>?, basectx: Context?) {

  var id: String
  var out: MutableMap<String, Any?> = linkedMapOf()
  var ctrl: Control = Control()
  var meta: MutableMap<String, Any?> = linkedMapOf()
  var client: SdkClient? = null
  var utility: Utility? = null
  lateinit var op: Operation
  var point: MutableMap<String, Any?>? = null
  var config: MutableMap<String, Any?>? = null
  var entopts: MutableMap<String, Any?>? = null
  var options: MutableMap<String, Any?>? = null
  var opmap: MutableMap<String, Operation>? = null
  var response: Response? = null
  var result: Result? = null
  var spec: Spec? = null
  var data: MutableMap<String, Any?> = linkedMapOf()
  var reqdata: MutableMap<String, Any?> = linkedMapOf()
  var match: MutableMap<String, Any?> = linkedMapOf()
  var reqmatch: MutableMap<String, Any?> = linkedMapOf()
  var entity: Entity? = null
  var shared: MutableMap<String, Any?>? = null

  init {
    this.id = "C" + (ThreadLocalRandom.current().nextInt(90000000) + 10000000)

    // Client
    val c = Helpers.getCtxProp(ctxmap, "client")
    if (c is SdkClient) {
      this.client = c
    }
    if (this.client == null && basectx != null) {
      this.client = basectx.client
    }

    // Utility
    val u = Helpers.getCtxProp(ctxmap, "utility")
    if (u is Utility) {
      this.utility = u
    }
    if (this.utility == null && basectx != null) {
      this.utility = basectx.utility
    }

    // Ctrl
    this.ctrl = Control()
    val cv = Helpers.getCtxProp(ctxmap, "ctrl")
    if (cv != null) {
      if (cv is MutableMap<*, *>) {
        val cm = cv as MutableMap<String, Any?>
        val t = cm["throw"]
        if (t is Boolean) {
          this.ctrl.throwing = t
        }
        val e = cm["explain"]
        if (e is MutableMap<*, *>) {
          this.ctrl.explain = e as MutableMap<String, Any?>
        }
        val a = cm["actor"]
        if (a is String) {
          this.ctrl.actor = a
        }
        val p = cm["paging"]
        if (p is MutableMap<*, *>) {
          this.ctrl.paging = p as MutableMap<String, Any?>
        }
      } else if (cv is Control) {
        this.ctrl = cv
      }
    } else if (basectx != null) {
      this.ctrl = basectx.ctrl
    }

    // Meta
    this.meta = linkedMapOf()
    val m = Helpers.getCtxProp(ctxmap, "meta")
    if (m is MutableMap<*, *>) {
      this.meta = m as MutableMap<String, Any?>
    } else if (basectx != null) {
      this.meta = basectx.meta
    }

    // Config
    val cfg = Helpers.getCtxProp(ctxmap, "config")
    if (cfg is MutableMap<*, *>) {
      this.config = cfg as MutableMap<String, Any?>
    }
    if (this.config == null && basectx != null) {
      this.config = basectx.config
    }

    // Entopts
    val eo = Helpers.getCtxProp(ctxmap, "entopts")
    if (eo is MutableMap<*, *>) {
      this.entopts = eo as MutableMap<String, Any?>
    }
    if (this.entopts == null && basectx != null) {
      this.entopts = basectx.entopts
    }

    // Options
    val o = Helpers.getCtxProp(ctxmap, "options")
    if (o is MutableMap<*, *>) {
      this.options = o as MutableMap<String, Any?>
    }
    if (this.options == null && basectx != null) {
      this.options = basectx.options
    }

    // Entity
    val e = Helpers.getCtxProp(ctxmap, "entity")
    if (e is Entity) {
      this.entity = e
    }
    if (this.entity == null && basectx != null) {
      this.entity = basectx.entity
    }

    // Shared
    val s = Helpers.getCtxProp(ctxmap, "shared")
    if (s is MutableMap<*, *>) {
      this.shared = s as MutableMap<String, Any?>
    }
    if (this.shared == null && basectx != null) {
      this.shared = basectx.shared
    }

    // Opmap
    val om = Helpers.getCtxProp(ctxmap, "opmap")
    if (om is MutableMap<*, *>) {
      this.opmap = om as MutableMap<String, Operation>
    }
    if (this.opmap == null && basectx != null) {
      this.opmap = basectx.opmap
    }
    if (this.opmap == null) {
      this.opmap = linkedMapOf()
    }

    // Data
    this.data = Helpers.toMapAny(Helpers.getCtxProp(ctxmap, "data")) ?: linkedMapOf()
    this.reqdata = Helpers.toMapAny(Helpers.getCtxProp(ctxmap, "reqdata")) ?: linkedMapOf()
    this.match = Helpers.toMapAny(Helpers.getCtxProp(ctxmap, "match")) ?: linkedMapOf()
    this.reqmatch = Helpers.toMapAny(Helpers.getCtxProp(ctxmap, "reqmatch")) ?: linkedMapOf()

    // Point
    val t = Helpers.getCtxProp(ctxmap, "point")
    if (t is MutableMap<*, *>) {
      this.point = t as MutableMap<String, Any?>
    }
    if (this.point == null && basectx != null) {
      this.point = basectx.point
    }

    // Spec
    val sp = Helpers.getCtxProp(ctxmap, "spec")
    if (sp is Spec) {
      this.spec = sp
    }
    if (this.spec == null && basectx != null) {
      this.spec = basectx.spec
    }

    // Result
    val r = Helpers.getCtxProp(ctxmap, "result")
    if (r is Result) {
      this.result = r
    }
    if (this.result == null && basectx != null) {
      this.result = basectx.result
    }

    // Response
    val resp = Helpers.getCtxProp(ctxmap, "response")
    if (resp is Response) {
      this.response = resp
    }
    if (this.response == null && basectx != null) {
      this.response = basectx.response
    }

    // Resolve operation
    val opname = Helpers.getCtxProp(ctxmap, "opname")
    this.op = resolveOp(if (opname is String) opname else "")
  }

  private fun resolveOp(opname: String): Operation {
    // Cache key is `<entity>:<opname>` so two entities with the same op
    // (e.g. both have a "list") get distinct cached Operations.
    var entname = ""
    if (this.entity != null) {
      entname = this.entity!!.name
    }
    val cacheKey = "$entname:$opname"

    val cached = this.opmap!![cacheKey]
    if (cached != null) {
      return cached
    }

    if ("" == opname) {
      return Operation(linkedMapOf())
    }

    val opcfg = Struct.getpath(this.config, listOf("entity", entname, "op", opname))

    var input = "match"
    if ("update" == opname || "create" == opname) {
      input = "data"
    }

    var points: MutableList<Any?>? = null
    if (opcfg is MutableMap<*, *>) {
      val t = Struct.getprop(opcfg, "points")
      if (t is MutableList<*>) {
        points = t as MutableList<Any?>
      }
    }
    if (points == null) {
      points = mutableListOf()
    }

    val opdef = linkedMapOf<String, Any?>()
    opdef["entity"] = entname
    opdef["name"] = opname
    opdef["input"] = input
    opdef["points"] = points

    val op = Operation(opdef)

    this.opmap!![cacheKey] = op
    return op
  }

  fun makeError(code: String, msg: String): SdkError {
    return SdkError(code, msg, this)
  }
}
