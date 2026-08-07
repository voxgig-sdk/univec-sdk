
function transformRequest(ctx) {
  const spec = ctx.spec
  const utility = ctx.utility
  const point = ctx.point
  const isfunc = utility.struct.isfunc
  const transform = utility.struct.transform

  if (spec) {
    spec.step = 'reqform'
  }

  try {
    const reqform = point.transform.req
    const reqdata = isfunc(reqform) ? reqform(ctx) : transform({
      reqdata: ctx.reqdata
    }, reqform)

    return reqdata
  }
  catch (err) {
    return utility.makeError(ctx, err)
  }
}

module.exports = {
  transformRequest
}
