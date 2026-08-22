// Load operation fragment (spliced into the entity class by
// EntityOperation_swift; only the EJECT region is emitted).

import Foundation

final class EntyClassLoadOpFragment: EntyClass {
// EJECT-START
public override func load(_ reqmatch: VMap?, _ ctrl: VMap?) throws -> Value {
  var ctxmap: [String: Any?] = ["opname": "load", "match": match, "data": data]
  if let ctrl = ctrl { ctxmap["ctrl"] = ctrl }
  if let reqmatch = reqmatch { ctxmap["reqmatch"] = reqmatch }
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
