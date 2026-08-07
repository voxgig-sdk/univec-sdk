
const { Spec } = require('../Spec')

// Create request specificaton.
function makeSpec(ctx) {
  if (ctx.out.spec) {
    return ctx.spec = ctx.out.spec
  }

  const point = ctx.point
  const options = ctx.options
  const utility = ctx.utility

  const prepareMethod = utility.prepareMethod
  const prepareParams = utility.prepareParams
  const prepareQuery = utility.prepareQuery
  const prepareHeaders = utility.prepareHeaders
  const prepareBody = utility.prepareBody
  const preparePath = utility.preparePath
  const prepareAuth = utility.prepareAuth

  ctx.spec = new Spec({
    base: options.base,
    prefix: options.prefix,
    parts: point.parts,
    suffix: options.suffix,
    step: 'start',
  })

  ctx.spec.method = prepareMethod(ctx)

  if (!options.allow.method.includes(ctx.spec.method)) {
    return ctx.error('spec_method_allow', 'Method "' + ctx.spec.method +
      '" not allowed by SDK option allow.method value: "' + options.allow.method + '"')
  }

  ctx.spec.params = prepareParams(ctx)
  ctx.spec.query = prepareQuery(ctx)
  ctx.spec.headers = prepareHeaders(ctx)
  ctx.spec.body = prepareBody(ctx)
  ctx.spec.path = preparePath(ctx)

  if (ctx.ctrl.explain) {
    ctx.ctrl.explain.spec = ctx.spec
  }

  const spec = prepareAuth(ctx)

  if (!(spec instanceof Error)) {
    ctx.spec = spec
  }

  return spec
}

module.exports = {
  makeSpec
}
