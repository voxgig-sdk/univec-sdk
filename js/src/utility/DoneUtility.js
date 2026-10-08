
const { clean } = require('./CleanUtility')

function done(ctx) {
  const error = ctx.utility.makeError

  cleanExplain(ctx)

  if (ctx.result && ctx.result.ok) {
    return ctx.result.resdata
  }

  return error(ctx)
}

// In place: the caller may hold the record, and a stream copies only its ctrl.
function cleanExplain(ctx) {
  const explain = ctx.ctrl.explain
  if (null == explain || 'object' !== typeof explain) {
    return
  }
  const cleaned = clean(ctx, explain)
  if (cleaned !== explain) {
    for (const k of Object.keys(explain)) delete explain[k]
    Object.assign(explain, cleaned)
  }
  // With clean off, explain.result is the live result makeError reads.
  if (null != explain.result) explain.result = ctx.utility.struct.delprop({ ...explain.result }, 'err')
}

module.exports = {
  cleanExplain,
  done
}
