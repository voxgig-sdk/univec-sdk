// Univec SDK - operation context.
//
// ctxmap is a loose Swift dictionary that carries a mix of typed pipeline
// objects (client, utility, entity, spec, ...) and loose Value maps (data,
// match, options, ...), mirroring the C# donor's Dictionary<string,object?>.

import Foundation

// ctxProp reads a value from the loose ctx dictionary.
func ctxProp(_ m: [String: Any?]?, _ key: String) -> Any? {
  guard let m = m, let v = m[key] else { return nil }
  return v
}

public final class Context {
  public var id: String = ""
  public var out: [String: Any?] = [:]
  public var ctrl: Control = Control()
  public var meta: VMap = VMap()
  public var client: UnivecSDK?
  public var utility: Utility?
  public var op: Operation?
  public var point: VMap?
  public var config: VMap?
  public var entopts: VMap?
  public var options: VMap?
  public var opmap: [String: Operation] = [:]
  public var response: Response?
  public var result: Result?
  public var spec: Spec?
  public var data: VMap = VMap()
  public var reqdata: VMap = VMap()
  public var match: VMap = VMap()
  public var reqmatch: VMap = VMap()
  public var entity: Entity?
  public var shared: VMap?

  public init(_ ctxmap: [String: Any?]?, _ basectx: Context?) {
    id = "C" + String(Int.random(in: 10_000_000...99_999_999))

    // Client
    if let sdk = ctxProp(ctxmap, "client") as? UnivecSDK { client = sdk }
    if client == nil, let b = basectx { client = b.client }

    // Utility
    if let util = ctxProp(ctxmap, "utility") as? Utility { utility = util }
    if utility == nil, let b = basectx { utility = b.utility }

    // Ctrl
    ctrl = Control()
    let rawctrl = ctxProp(ctxmap, "ctrl")
    if let c = rawctrl as? Control {
      ctrl = c
    } else if let cm = rawctrl as? VMap {
      if let t = cm.entries["throw"]?.asBool { ctrl.throwErr = t }
      if let e = cm.entries["explain"]?.asMap { ctrl.explain = e }
      if let a = cm.entries["actor"]?.asString { ctrl.actor = a }
      if let p = cm.entries["paging"]?.asMap { ctrl.paging = p }
    } else if let b = basectx, ctxProp(ctxmap, "opname") == nil {
      ctrl = b.ctrl
    }

    // Meta
    meta = VMap()
    if let mm = ctxProp(ctxmap, "meta") as? VMap {
      meta = mm
    } else if let b = basectx {
      meta = b.meta
    }

    // Config
    if let cfg = ctxProp(ctxmap, "config") as? VMap { config = cfg }
    if config == nil, let b = basectx { config = b.config }

    // Entopts
    if let eo = ctxProp(ctxmap, "entopts") as? VMap { entopts = eo }
    if entopts == nil, let b = basectx { entopts = b.entopts }

    // Options
    if let om = ctxProp(ctxmap, "options") as? VMap { options = om }
    if options == nil, let b = basectx { options = b.options }

    // Entity
    if let ent = ctxProp(ctxmap, "entity") as? Entity { entity = ent }
    if entity == nil, let b = basectx { entity = b.entity }

    // Shared
    if let sh = ctxProp(ctxmap, "shared") as? VMap { shared = sh }
    if shared == nil, let b = basectx { shared = b.shared }

    // Opmap
    if let opm = ctxProp(ctxmap, "opmap") as? [String: Operation] {
      opmap = opm
    } else if let b = basectx {
      opmap = b.opmap
    }

    // Data maps
    data = (ctxProp(ctxmap, "data") as? VMap) ?? VMap()
    reqdata = (ctxProp(ctxmap, "reqdata") as? VMap) ?? VMap()
    match = (ctxProp(ctxmap, "match") as? VMap) ?? VMap()
    reqmatch = (ctxProp(ctxmap, "reqmatch") as? VMap) ?? VMap()

    // Point
    if let tm = ctxProp(ctxmap, "point") as? VMap { point = tm }
    if point == nil, let b = basectx { point = b.point }

    // Spec
    if let sp = ctxProp(ctxmap, "spec") as? Spec { spec = sp }
    if spec == nil, let b = basectx { spec = b.spec }

    // Result
    if let res = ctxProp(ctxmap, "result") as? Result { result = res }
    if result == nil, let b = basectx { result = b.result }

    // Response
    if let resp = ctxProp(ctxmap, "response") as? Response { response = resp }
    if response == nil, let b = basectx { response = b.response }

    // Resolve operation
    let opname = ctxProp(ctxmap, "opname") as? String ?? ""
    op = resolveOp(opname)
  }

  private func resolveOp(_ opname: String) -> Operation {
    // Cache key `<entity>:<opname>` so two entities with the same op get
    // distinct cached Operations.
    let entname = entity?.getName() ?? ""
    let cacheKey = entname + ":" + opname

    if let cached = opmap[cacheKey] { return cached }

    if opname == "" {
      return Operation(VMap())
    }

    let store: Value = config == nil ? .noval : .map(config!)
    let opcfg = getpath(store, jtp("entity", entname, "op", opname))

    let input = (opname == "update" || opname == "create" || opname == "patch") ? "data" : "match"

    var points: VList = VList()
    if let ocm = opcfg.asMap, let tl = ocm.entries["points"]?.asList {
      points = tl
    }

    let opm = VMap()
    opm.entries["entity"] = .string(entname)
    opm.entries["name"] = .string(opname)
    opm.entries["input"] = .string(input)
    opm.entries["points"] = .list(points)

    // Each context holds its own copy of the cache, so a request racing
    // another builds its own Operation, a read-only descriptor.
    let op = Operation(opm)
    opmap[cacheKey] = op
    return op
  }

  public func makeError(_ code: String, _ msg: String) -> UnivecError {
    return UnivecError(code, msg, self)
  }

  // The record form: what the context says about the operation, never its
  // client, options or config.
  func rawRecord() -> VMap {
    let record = VMap()
    record.entries["id"] = .string(id)
    record.entries["op"] = op == nil ? .noval : .nat(op!)
    record.entries["spec"] = spec == nil ? .noval : .nat(spec!)
    record.entries["entity"] = entity == nil ? .noval : .string(entity!.getName())
    record.entries["result"] = result == nil ? .noval : .nat(result!)
    record.entries["response"] = response == nil ? .noval : .nat(response!)
    record.entries["meta"] = .map(meta)
    return record
  }

  // The serialised context leaves the pipeline (a logger, an error dump), so
  // it is cleaned; the live fields stay raw for the pipeline's own use.
  public func record() -> VMap {
    let record = rawRecord()
    guard let clean = utility?.clean else { return record }
    return clean(self, .map(record)).asMap ?? record
  }
}

// Every default print of a context is the cleaned record, `dump` included.
extension Context: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public var description: String { "Context " + jsonify(.map(record()), indent: 0) }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: ["record": jsonify(.map(record()), indent: 0)]) }
}
