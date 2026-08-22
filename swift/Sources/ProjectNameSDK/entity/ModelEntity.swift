// Model entity client for the Univec SDK.

import Foundation

public final class ModelEntity: UnivecEntityBase {
  public init(_ client: UnivecSDK, _ entopts: VMap? = nil) {
    super.init(client, entopts, "model")
  }

  public override func make() -> Entity {
    return ModelEntity(client, cloneOpts())
  }

  // (load not defined by this API - base class throws unsupportedOp)

  public override func list(_ reqmatch: VMap?, _ ctrl: VMap?) throws -> Value {
    var ctxmap: [String: Any?] = ["opname": "list", "match": match, "data": data]
    if let ctrl = ctrl { ctxmap["ctrl"] = ctrl }
    if let reqmatch = reqmatch { ctxmap["reqmatch"] = reqmatch }
    let ctx = utility.makeContext(ctxmap, entctx)
  
    return try runOp(ctx) {
      if let result = ctx.result {
        if let rm = result.resmatch { self.match = rm }
      }
    }
  }

  // (create not defined by this API - base class throws unsupportedOp)

  // (update not defined by this API - base class throws unsupportedOp)

  // (remove not defined by this API - base class throws unsupportedOp)
}
