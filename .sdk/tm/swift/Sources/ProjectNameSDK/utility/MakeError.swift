// Univec SDK utility: makeError - the single error surface of the
// pipeline. Throws the wrapped UnivecError unless the per-call ctrl
// disables throwing (ctrl.throw == false), in which case it returns the
// (possibly nil) result data instead.

import Foundation

func makeErrorUtil(_ ctx: Context, _ err: Error?) throws -> Value {
  let op = ctx.op ?? Operation(VMap())
  var opname = op.name
  if opname == "" || opname == "_" {
    opname = "unknown operation"
  }

  let result = ctx.result ?? Result(nil)
  result.ok = false

  var e = err
  if e == nil { e = result.err }
  if e == nil { e = ctx.makeError("unknown", "unknown error") }

  let errmsg = errMessage(e!)
  let msg = "UnivecSDK: " + opname + ": " + errmsg

  result.err = nil

  let spec = ctx.spec

  // The context stays reachable on the error for a debugger; the error type
  // keeps it out of every printer and mirror.
  let code = (e as? UnivecError)?.code ?? ""
  let sdkErr = UnivecError(code, msg, ctx)

  _ = cleanUtil(ctx, .nat(sdkErr))

  // The HTTP status at the top level, so a consumer can branch on
  // err.status instead of reaching into err.resultVal.
  sdkErr.status = result.status

  if let explain = ctx.ctrl.explain {
    let em = VMap()
    em.entries["code"] = .string(sdkErr.code)
    em.entries["message"] = .string(sdkErr.message)
    em.entries["status"] = .int(Int64(sdkErr.status))
    explain.entries["err"] = .map(em)
  }

  sdkErr.resultVal = cleanUtil(ctx, .nat(result))
  sdkErr.specVal = spec == nil ? .noval : cleanUtil(ctx, .nat(spec!))

  ctx.ctrl.err = sdkErr

  // Fire PreUnexpected so observability features (metrics, telemetry, audit,
  // debug) close/record error paths that never reach PreDone (e.g. a PrePoint
  // rbac short-circuit). Fires after ctx.ctrl.err is set so hooks can read the
  // error; features guard against double-recording when PreDone already fired.
  if let utility = ctx.utility {
    utility.featureHook(ctx, "PreUnexpected")
  }

  if ctx.ctrl.throwErr == false {
    return result.resdata
  }

  throw sdkErr
}
