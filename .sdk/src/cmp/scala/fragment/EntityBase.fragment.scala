package SCALAPACKAGE.entity

import java.util.{ArrayList, LinkedHashMap, Iterator => JIterator, List => JList, Map => JMap}
import SCALAPACKAGE.core.{Context, Helpers, SdkClient, SdkEntity, Utility}
import SCALAPACKAGE.utility.struct.Struct

// Shared entity runtime for the ProjectName SDK: accreting data/match state,
// the entity context, and the operation pipeline (runOp) with its feature
// hooks. Generated entity classes extend this.
abstract class EntityBase(name0: String, client0: SdkClient, entopts0: JMap[String, Object]) extends SdkEntity {

  protected var name: String = name0
  protected var client: SdkClient = client0
  protected var utility: Utility = null
  protected var entopts: JMap[String, Object] = null
  protected var dataState: JMap[String, Object] = new LinkedHashMap[String, Object]()
  protected var matchState: JMap[String, Object] = new LinkedHashMap[String, Object]()
  protected var entctx: Context = null

  locally {
    var eo = entopts0
    if (eo == null) eo = new LinkedHashMap[String, Object]()
    if (!eo.containsKey("active")) eo.put("active", java.lang.Boolean.TRUE)
    else if (java.lang.Boolean.FALSE == eo.get("active")) { /* keep false */ }
    else eo.put("active", java.lang.Boolean.TRUE)

    this.entopts = eo
    this.utility = client0.getUtility()

    val ctxmap = new LinkedHashMap[String, Object]()
    ctxmap.put("entity", this)
    ctxmap.put("entopts", eo)
    this.entctx = this.utility.makeContext(ctxmap, client0.getRootCtx())

    this.utility.featureHook(this.entctx, "PostConstructEntity")
  }

  def getName(): String = this.name

  override def data(args: Object*): Object = {
    if (args.length > 0 && args(0) != null) {
      val d = Helpers.toMapAny(Struct.clone(args(0)))
      this.dataState = if (d == null) new LinkedHashMap[String, Object]() else d
      this.utility.featureHook(this.entctx, "SetData")
    }
    this.utility.featureHook(this.entctx, "GetData")
    Struct.clone(this.dataState)
  }

  override def matchArgs(args: Object*): Object = {
    if (args.length > 0 && args(0) != null) {
      val m = Helpers.toMapAny(Struct.clone(args(0)))
      this.matchState = if (m == null) new LinkedHashMap[String, Object]() else m
      this.utility.featureHook(this.entctx, "SetMatch")
    }
    this.utility.featureHook(this.entctx, "GetMatch")
    Struct.clone(this.matchState)
  }

  // runOp drives one operation through the pipeline: for each stage the
  // feature hook fires, then the stage runs; a failing stage routes through
  // makeError (which throws, or returns fallback data when ctrl.throw false).
  // Every operation resolves to the entity; `remove` additionally marks
  // it. The instance KEEPS the data it held — a caller can still read
  // what was deleted — but it is no longer a live record. See AGENTS.md.
  private var deletedFlag: Boolean = false

  def markDeleted(): Unit = { deletedFlag = true }

  def deleted(): Boolean = deletedFlag


  protected def runOp(ctx: Context, postDone: () => Unit): Object = {
    val utility = this.utility

    try {
// #PrePoint-Hook

      val point = utility.makePoint(ctx)
      ctx.out.put("point", point)

// #PreSpec-Hook

      val spec = utility.makeSpec(ctx)
      ctx.out.put("spec", spec)

// #PreRequest-Hook

      val request = utility.makeRequest(ctx)
      ctx.out.put("request", request)

// #PreResponse-Hook

      val response = utility.makeResponse(ctx)
      ctx.out.put("response", response)

// #PreResult-Hook

      val result = utility.makeResult(ctx)
      ctx.out.put("result", result)

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
      val opname = if (ctx.op == null) null else ctx.op.name

      if (ctx.result != null && ctx.result.ok && "list" != opname) {
        if ("remove" == opname) markDeleted()
        this
      }
      else out
    } catch {
      case err: RuntimeException =>
        // An error already finalised by makeError must not be wrapped twice.
        if (err eq ctx.ctrl.err) throw err
        utility.makeError(ctx, err)
    }
  }

  // Streaming operations. Runs `action` through the full pipeline and returns
  // an Iterator over result items, so the streaming feature's incremental
  // output is reachable from a generated entity (a normal op call materialises
  // the whole result). `callopts` parameterises the call:
  //   - inbound (download): iterate the yielded items/chunks (from the
  //     streaming feature when active, else the materialised items);
  //   - outbound (upload): pass a streamable payload as callopts["body"] - it
  //     is attached to the request so the transport can send it;
  //   - callopts["ctrl"] threads pipeline control and callopts["signal"] (a
  //     () => Boolean that returns true when aborted) is honoured between
  //     yields.
  override def stream(action: String, args: JMap[String, Object],
      callopts: JMap[String, Object]): Iterator[Object] = {
    val opts = if (callopts == null) new LinkedHashMap[String, Object]() else callopts

    val signal = opts.get("signal")

    var ctrl = Helpers.toMapAny(opts.get("ctrl"))
    if (ctrl == null) ctrl = new LinkedHashMap[String, Object]()
    ctrl.put("stream", opts)

    val ctxmap = new LinkedHashMap[String, Object]()
    ctxmap.put("opname", action)
    ctxmap.put("ctrl", ctrl)
    ctxmap.put("match", this.matchState)
    ctxmap.put("data", this.dataState)
    if (args != null) ctxmap.putAll(args)

    val ctx = this.utility.makeContext(ctxmap, this.entctx)

    // Outbound: expose the caller's streamable payload so the request builder
    // / transport can stream it as the request body.
    val body = opts.get("body")
    if (body != null) {
      ctx.reqdata.put("body$", body)
      ctx.ctrl.streamOut = body
    }

    // Run the same pipeline the op methods run.
    val materialised = runOp(ctx, () => {})

    // Inbound: prefer the streaming feature's incremental iterator; else fall
    // back to the materialised items so `stream` always yields.
    val source: JIterator[Object] =
      if (ctx.result != null && ctx.result.stream != null) ctx.result.stream.get()
      else {
        val items: JList[Object] = materialised match {
          case l: JList[_] => l.asInstanceOf[JList[Object]]
          case null => new ArrayList[Object]()
          case other => { val a = new ArrayList[Object](); a.add(other); a }
        }
        items.iterator()
      }

    val aborted: () => Boolean = signal match {
      case f: Function0[_] => () => f.asInstanceOf[Function0[Object]].apply() == java.lang.Boolean.TRUE
      case _ => () => false
    }

    new Iterator[Object] {
      override def hasNext: Boolean = !aborted() && source.hasNext
      override def next(): Object = source.next()
    }
  }
}
