package KOTLINPACKAGE.entity

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.Helpers
import KOTLINPACKAGE.core.SdkClient
import KOTLINPACKAGE.core.SdkEntity
import KOTLINPACKAGE.core.Utility
import KOTLINPACKAGE.utility.struct.Struct

/**
 * Shared entity runtime for the ProjectName SDK: accreting data/match state,
 * the entity context, and the operation pipeline (runOp) with its feature
 * hooks. Generated entity classes extend this.
 */
@Suppress("UNCHECKED_CAST")
abstract class EntityBase(nm: String, clientIn: SdkClient, entoptsIn: MutableMap<String, Any?>?) : SdkEntity {

  override var name: String = ""
  protected var client: SdkClient
  protected var utility: Utility
  protected var entopts: MutableMap<String, Any?>
  protected var data: MutableMap<String, Any?> = linkedMapOf()
  protected var match: MutableMap<String, Any?> = linkedMapOf()
  protected var entctx: Context

  init {
    val entopts = entoptsIn ?: linkedMapOf()
    if (!entopts.containsKey("active")) {
      entopts["active"] = true
    } else if (entopts["active"] == false) {
      // keep false
    } else {
      entopts["active"] = true
    }

    this.name = nm
    this.client = clientIn
    this.utility = clientIn.getUtility()
    this.entopts = entopts

    val ctxmap = linkedMapOf<String, Any?>()
    ctxmap["entity"] = this
    ctxmap["entopts"] = entopts
    this.entctx = this.utility.makeContext(ctxmap, clientIn.getRootCtx())

    this.utility.featureHook(this.entctx, "PostConstructEntity")
  }

  override fun data(vararg args: Any?): Any? {
    if (args.isNotEmpty() && args[0] != null) {
      val d = Helpers.toMapAny(Struct.clone(args[0]))
      this.data = d ?: linkedMapOf()
      this.utility.featureHook(this.entctx, "SetData")
    }

    this.utility.featureHook(this.entctx, "GetData")
    return Struct.clone(this.data)
  }

  override fun match(vararg args: Any?): Any? {
    if (args.isNotEmpty() && args[0] != null) {
      val m = Helpers.toMapAny(Struct.clone(args[0]))
      this.match = m ?: linkedMapOf()
      this.utility.featureHook(this.entctx, "SetMatch")
    }

    this.utility.featureHook(this.entctx, "GetMatch")
    return Struct.clone(this.match)
  }

  // runOp drives one operation through the pipeline: for each stage the
  // feature hook fires, then the stage runs; a failing stage routes through
  // makeError (which throws, or returns fallback data when ctrl.throw false).
  // Every operation resolves to the entity; `remove` additionally marks
  // it. The instance KEEPS the data it held — a caller can still read
  // what was deleted — but it is no longer a live record. See AGENTS.md.
  private var deletedFlag: Boolean = false

  fun markDeleted() {
    this.deletedFlag = true
  }

  fun deleted(): Boolean = this.deletedFlag


  protected fun runOp(ctx: Context, postDone: () -> Unit): Any? {
    val utility = this.utility

    try {
// #PrePoint-Hook

      val point = utility.makePoint(ctx)
      ctx.out["point"] = point

// #PreSpec-Hook

      val spec = utility.makeSpec(ctx)
      ctx.out["spec"] = spec

// #PreRequest-Hook

      val request = utility.makeRequest(ctx)
      ctx.out["request"] = request

// #PreResponse-Hook

      val response = utility.makeResponse(ctx)
      ctx.out["response"] = response

// #PreResult-Hook

      val result = utility.makeResult(ctx)
      ctx.out["result"] = result

// #PreDone-Hook

      postDone()

      val out = utility.done(ctx)

      // An operation resolves to the ENTITY, not the raw data. Entities are
      // stateful: postDone has just absorbed resdata/resmatch into this
      // instance, and the caller reaches the record through data(). Two
      // structural exceptions: `list` resolves to the ARRAY of entity
      // instances makeResult built, and a failed op with throwing disabled
      // hands back the error payload unchanged. `remove` additionally marks
      // the entity deleted; it KEEPS its data, so a caller can still read
      // what was removed. See AGENTS.md "Entity operations return ENTITIES".
      val opname = ctx.op?.name

      if (ctx.result != null && ctx.result!!.ok && "list" != opname) {
        if ("remove" == opname) {
          this.markDeleted()
        }
        return this
      }

      return out
    } catch (err: RuntimeException) {
      // An error already finalised by makeError (e.g. via done) must not be
      // wrapped a second time.
      if (err === ctx.ctrl.err) {
        throw err
      }
      return utility.makeError(ctx, err)
    }
  }

  /**
   * Streaming operations. Runs `action` through the full pipeline and returns
   * a Sequence over result items, so the streaming feature's incremental
   * output is reachable from a generated entity (a normal op call materialises
   * the whole result). `callopts` parameterises the call:
   *   - inbound (download): iterate the yielded items/chunks (from the
   *     streaming feature when active, else the materialised items);
   *   - outbound (upload): pass a streamable payload as callopts["body"] - it
   *     is attached to the request so the transport can send it;
   *   - callopts["ctrl"] threads pipeline control and callopts["signal"] (a
   *     () -> Boolean that returns true when aborted) is honoured between
   *     yields.
   */
  override fun stream(
    action: String,
    args: MutableMap<String, Any?>?,
    callopts: MutableMap<String, Any?>?,
  ): Sequence<Any?> {
    val opts = callopts ?: linkedMapOf()

    val signal = opts["signal"]

    val ctrl = Helpers.toMapAny(opts["ctrl"]) ?: linkedMapOf()
    ctrl["stream"] = opts

    val ctxmap = linkedMapOf<String, Any?>()
    ctxmap["opname"] = action
    ctxmap["ctrl"] = ctrl
    ctxmap["match"] = this.match
    ctxmap["data"] = this.data
    if (args != null) {
      ctxmap.putAll(args)
    }

    val ctx = this.utility.makeContext(ctxmap, this.entctx)

    // Outbound: expose the caller's streamable payload so the request builder
    // / transport can stream it as the request body.
    val body = opts["body"]
    if (body != null) {
      ctx.reqdata["body\$"] = body
      ctx.ctrl.streamOut = body
    }

    // Run the same pipeline the op methods run.
    val materialised = runOp(ctx) {}

    // Inbound: prefer the streaming feature's incremental iterator; else fall
    // back to the materialised items so `stream` always yields.
    val source: Iterator<Any?> = ctx.result?.stream?.get()
      ?: run {
        val items: List<Any?> = when (materialised) {
          is List<*> -> materialised
          null -> emptyList()
          else -> listOf(materialised)
        }
        items.iterator()
      }

    val aborted: () -> Boolean = when (signal) {
      is Function0<*> -> {
        { (signal as Function0<Any?>).invoke() == true }
      }
      else -> {
        { false }
      }
    }

    return sequence {
      while (source.hasNext()) {
        if (aborted()) {
          return@sequence
        }
        yield(source.next())
      }
    }
  }
}
