// ProjectNameEntityBase - shared entity behaviour: construction, data/match
// state (with feature hooks), the operation pipeline (runOp) and default
// unsupported-op implementations of every CRUD method. Generated entity
// classes derive from this and override the operations their API defines.

import Foundation

open class ProjectNameEntityBase: Entity {
  var name: String
  var client: ProjectNameSDK
  var utility: Utility
  var entopts: VMap
  var data = VMap()
  var match = VMap()
  var entctx: Context!

  public init(_ client: ProjectNameSDK, _ entoptsIn: VMap?, _ name: String) {
    let entopts = entoptsIn ?? VMap()
    if entopts.entries["active"] == nil {
      entopts.entries["active"] = .bool(true)
    } else if entopts.entries["active"] != .bool(false) {
      entopts.entries["active"] = .bool(true)
    }

    self.name = name
    self.client = client
    self.utility = client.getUtility()
    self.entopts = entopts

    self.entctx = utility.makeContext(["entity": self, "entopts": entopts], client.getRootCtx())

    utility.featureHook(entctx, "PostConstructEntity")
  }

  public func getName() -> String { name }

  open func make() -> Entity {
    return ProjectNameEntityBase(client, cloneOpts(), name)
  }

  func cloneOpts() -> VMap {
    let m = VMap()
    for (k, v) in entopts.entries { m.entries[k] = v }
    return m
  }

  @discardableResult
  public func data(_ newdata: Value?) -> Value {
    if let nd = newdata, !isNil(nd) {
      data = clone(nd).asMap ?? VMap()
      utility.featureHook(entctx, "SetData")
    }
    utility.featureHook(entctx, "GetData")
    return clone(.map(data))
  }

  @discardableResult
  public func matchv(_ newmatch: Value?) -> Value {
    if let nm = newmatch, !isNil(nm) {
      match = clone(nm).asMap ?? VMap()
      utility.featureHook(entctx, "SetMatch")
    }
    utility.featureHook(entctx, "GetMatch")
    return clone(.map(match))
  }

  open func load(_ reqmatch: VMap?, _ ctrl: VMap?) throws -> Value {
    throw unsupportedOp("load", name)
  }

  open func list(_ reqmatch: VMap?, _ ctrl: VMap?) throws -> Value {
    throw unsupportedOp("list", name)
  }

  open func create(_ reqdata: VMap?, _ ctrl: VMap?) throws -> Value {
    throw unsupportedOp("create", name)
  }

  open func update(_ reqdata: VMap?, _ ctrl: VMap?) throws -> Value {
    throw unsupportedOp("update", name)
  }

  open func remove(_ reqmatch: VMap?, _ ctrl: VMap?) throws -> Value {
    throw unsupportedOp("remove", name)
  }

  // Every operation resolves to the entity; `remove` additionally marks
  // it. The instance KEEPS the data it held — a caller can still read
  // what was deleted — but it is no longer a live record. See AGENTS.md.
  private var deletedFlag: Bool = false

  public func markDeleted() {
    self.deletedFlag = true
  }

  public func deleted() -> Bool {
    return self.deletedFlag
  }


  func runOp(_ ctx: Context, _ postDone: () -> Void) throws -> Value {
    // #PrePoint-Hook

    do {
      let point = try utility.makePoint(ctx)
      ctx.out["point"] = point
    } catch {
      return try utility.makeError(ctx, error)
    }

    // #PreSpec-Hook

    do {
      let spec = try utility.makeSpec(ctx)
      ctx.out["spec"] = spec
    } catch {
      return try utility.makeError(ctx, error)
    }

    // #PreRequest-Hook

    do {
      let resp = try utility.makeRequest(ctx)
      ctx.out["request"] = resp
    } catch {
      return try utility.makeError(ctx, error)
    }

    // #PreResponse-Hook

    do {
      let resp2 = try utility.makeResponse(ctx)
      ctx.out["response"] = resp2
    } catch {
      return try utility.makeError(ctx, error)
    }

    // #PreResult-Hook

    do {
      let result = try utility.makeResult(ctx)
      ctx.out["result"] = result
    } catch {
      return try utility.makeError(ctx, error)
    }

    // #PreDone-Hook

    postDone()

    let out = try utility.done(ctx)

    // An operation resolves to the ENTITY, not the raw data. Entities are
    // stateful: postDone has just absorbed resdata/resmatch into this
    // instance, and the caller reaches the record through data(). Two
    // structural exceptions: `list` resolves to the ARRAY of entity
    // instances makeResult built, and a failed op with throwing disabled
    // hands back the error payload unchanged. `remove` additionally marks
    // the entity deleted; it KEEPS its data, so a caller can still read
    // what was removed. See AGENTS.md "Entity operations return ENTITIES".
    let opname = ctx.op?.name

    if let result = ctx.result, result.ok, "list" != opname {
      if "remove" == opname {
        self.markDeleted()
      }
      return .native(NativeRef(self))
    }

    return out
  }

  // Streaming operations. Runs `action` through the full pipeline and returns
  // an AsyncStream over result items, so the `streaming` feature's incremental
  // output is reachable from a generated entity (a normal op call materialises
  // the whole result). `callopts` parameterises the call:
  //   - inbound (download): iterate the yielded items/chunks (from the
  //     streaming feature when active, else the materialised items);
  //   - outbound (upload): pass a streamable payload as callopts["body"] - it
  //     is attached to the request so the transport can send it;
  //   - callopts["ctrl"] threads pipeline control and callopts["signal"] (a
  //     native () -> Bool that returns true when aborted) is honoured between
  //     yields.
  public func stream(_ action: String, _ args: VMap? = nil, _ callopts: VMap? = nil)
    throws -> AsyncStream<Value>
  {
    let opts = callopts ?? VMap()

    let signal = opts.entries["signal"]?.asNative as? @Sendable () -> Bool

    let ctrl = opts.entries["ctrl"]?.asMap ?? VMap()
    ctrl.entries["stream"] = .map(opts)

    var ctxmap: [String: Any?] = [
      "opname": action,
      "ctrl": ctrl,
      "match": match,
      "data": data,
    ]
    if let a = args {
      for (k, v) in a.entries { ctxmap[k] = v }
    }

    let ctx = utility.makeContext(ctxmap, entctx)

    // Outbound: expose the caller's streamable payload so the request builder
    // / transport can stream it as the request body.
    if let body = opts.entries["body"], !isNil(body) {
      ctx.reqdata.entries["body$"] = body
      ctx.ctrl.streamOut = body
    }

    // Run the same pipeline the op methods run.
    let materialised = try runOp(ctx, {})

    // Inbound: prefer the streaming feature's incremental iterator; else fall
    // back to the materialised items so `stream` always yields.
    var items: [Value] = []
    if let result = ctx.result, let streamFn = result.stream {
      items = streamFn()
    } else if let list = materialised.asList {
      items = list.items
    } else if !isNil(materialised) {
      items = [materialised]
    }

    return AsyncStream { continuation in
      for item in items {
        if let s = signal, s() { break }
        continuation.yield(item)
      }
      continuation.finish()
    }
  }
}
