
function prepareBody(ctx) {
  const op = ctx.op

  const utility = ctx.utility
  const error = utility.makeError
  const transformRequest = utility.transformRequest

  let body = undefined

  if ('data' === op.input) {
    try {
      body = transformRequest(ctx)
    }
    catch (err) {
      return error(ctx, err)
    }
  }

  return body
}

module.exports = {
  prepareBody
}
