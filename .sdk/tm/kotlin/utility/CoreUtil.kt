package KOTLINPACKAGE.utility

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.Helpers
import KOTLINPACKAGE.core.Result
import KOTLINPACKAGE.core.SdkError
import KOTLINPACKAGE.core.Spec

fun makeContext(ctxmap: MutableMap<String, Any?>?, basectx: Context?): Context {
  return Context(ctxmap, basectx)
}

fun clean(ctx: Context, value: Any?): Any? {
  return value
}

@Suppress("UNCHECKED_CAST")
fun done(ctx: Context): Any? {
  val explain = ctx.ctrl.explain
  if (explain != null) {
    val cleaned = clean(ctx, explain) as MutableMap<String, Any?>
    ctx.ctrl.explain = cleaned
    val rm = Helpers.toMapAny(cleaned["result"])
    rm?.remove("err")
  }

  val result = ctx.result
  if (result != null && result.ok) {
    return result.resdata
  }

  return makeError(ctx, null)
}

// makeError finalises a failed operation: wraps the causing error in an
// SdkError carrying the cleaned result and spec, records it on ctx.ctrl,
// and either throws it (default) or — when ctrl.throw is false — returns
// the result's fallback resdata instead.
fun makeError(ctx: Context, errIn: RuntimeException?): Any? {
  var opname = ctx.op.name
  if ("" == opname || "_" == opname) {
    opname = "unknown operation"
  }

  var result = ctx.result
  if (result == null) {
    result = Result(linkedMapOf())
  }
  result.ok = false

  var err = errIn
  if (err == null) {
    err = result.err
  }
  if (err == null) {
    err = ctx.makeError("unknown", "unknown error")
  }

  val errmsg = err.message ?: err.toString()
  var msg = "UnivecSDK: $opname: $errmsg"
  msg = clean(ctx, msg) as String

  result.err = null

  val spec = ctx.spec

  val explain = ctx.ctrl.explain
  if (explain != null) {
    val errRecord = linkedMapOf<String, Any?>()
    errRecord["message"] = msg
    explain["err"] = errRecord
  }

  var code = ""
  if (err is SdkError) {
    code = err.code
  }

  val sdkErr = SdkError(code, msg, ctx)
  sdkErr.result = clean(ctx, result)
  sdkErr.spec = clean(ctx, spec)

  ctx.ctrl.err = sdkErr

  // Fire PreUnexpected so observability features (metrics, telemetry, audit,
  // debug) close/record error paths that never reach PreDone (e.g. a PrePoint
  // rbac short-circuit). Fires after ctx.ctrl.err is set so hooks can read the
  // error; features guard against double-recording when PreDone already fired.
  ctx.utility?.let { it.featureHook(ctx, "PreUnexpected") }

  if (ctx.ctrl.throwing == false) {
    return result.resdata
  }

  throw sdkErr
}
