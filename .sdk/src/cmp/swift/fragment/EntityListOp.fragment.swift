// List operation fragment (spliced into the entity class by
// EntityOperation_swift; only the EJECT region is emitted).

import Foundation

final class EntyClassListOpFragment: EntyClass {
// EJECT-START
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
// EJECT-END
}
