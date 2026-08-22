// Update operation fragment (spliced into the entity class by
// EntityOperation_swift; only the EJECT region is emitted).

import Foundation

final class EntyClassUpdateOpFragment: EntyClass {
// EJECT-START
public override func update(_ reqdata: VMap?, _ ctrl: VMap?) throws -> Value {
  var ctxmap: [String: Any?] = ["opname": "update", "match": match, "data": data]
  if let ctrl = ctrl { ctxmap["ctrl"] = ctrl }
  if let reqdata = reqdata { ctxmap["reqdata"] = reqdata }
  let ctx = utility.makeContext(ctxmap, entctx)

  return try runOp(ctx) {
    if let result = ctx.result {
      if let rm = result.resmatch { self.match = rm }
      if !isNil(result.resdata) {
        self.data = clone(result.resdata).asMap ?? VMap()
      }
    }
  }
}
// EJECT-END
}
