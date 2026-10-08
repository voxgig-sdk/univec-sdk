
const { isRawRequest, rawBody } = require('./MediaUtility')

function prepareBody(ctx) {
  const op = ctx.op

  const utility = ctx.utility
  const error = utility.makeError
  const transformRequest = utility.transformRequest

  let body = undefined

  if ('data' === op.input) {
    if (isRawRequest(ctx.point)) {
      return rawBody(ctx.reqdata)
    }

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
