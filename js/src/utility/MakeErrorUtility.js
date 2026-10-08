
const { Result } = require('../Result')

const { clean, setMessage } = require('./CleanUtility')
const { clone, delprop } = require('./StructUtility')

function makeError(ctx, err) {

  ctx = ctx || {}
  const op = ctx.op || {}
  op.name = op.name || 'unknown operation'

  const result = ctx.result || new Result({})
  result.ok = false

  const reserr = result.err

  err = undefined === err ? reserr : err
  err = err || ctx.error('unknown', 'unknown error')

  // A hook or fetcher may reject with a plain value; clean returns a masked
  // copy of that rather than changing it, so the copy is what leaves.
  if (!(err instanceof Error)) {
    const copy = clean(ctx, err)
    const text = 'string' === typeof copy ? copy : String(copy?.message ?? 'unknown error')
    err = Object.assign(new Error(text), 'object' === typeof copy ? copy : {})
  }

  const errmsg = err.message || 'unknown error'
  setMessage(err, 'UnivecSDK: ' + op.name + ': ' + errmsg)

  // The context stays reachable for a debugger, but not for a serialiser:
  // a transport error carries none, and a pipeline error's is enumerable
  // only until here.
  if (null != err.ctx) {
    Object.defineProperty(err, 'ctx', { value: err.ctx, enumerable: false, writable: true })
  }

  clean(ctx, err)

  if (result.err) {
    delprop(result, 'err')
  }

  const spec = ctx.spec || {}

  if (ctx.ctrl.explain) {
    ctx.ctrl.explain.err = {
      ...clone({ err }).err,
      message: err.message,
      stack: err.stack,
    }
  }

  err.result = clean(ctx, result)
  err.spec = clean(ctx, spec)

  // Promote the HTTP status to the top level, so a consumer can branch on
  // `err.status` / `err.notFound` instead of reaching into `err.result`.
  err.status = null == result.status ? -1 : result.status

  ctx.ctrl.err = err

  // Fire PreUnexpected so observability features (metrics, telemetry, audit,
  // debug) close/record error paths that never reach PreDone (e.g. a PrePoint
  // rbac short-circuit). Fires after ctx.ctrl.err is set so hooks can read the
  // error; features guard against double-recording when PreDone already fired.
  if (null != ctx.client && null != ctx.utility &&
    'function' === typeof ctx.utility.featureHook) {
    ctx.utility.featureHook(ctx, 'PreUnexpected')
  }

  // TODO: model option to return instead
  if (false === ctx.ctrl.throw) {
    return result.resdata
  }
  else {
    throw err
  }
}

module.exports = {
  makeError
}
