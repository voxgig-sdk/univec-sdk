
const { Spec } = require('../Spec')
const { allowed } = require('./PrepareMethodUtility')

// Create request specificaton.
function makeSpec(ctx) {
  // A PreSpec hook (validate) rejects the operation by placing its error
  // here; the pipeline raises it, and ctx.spec stays a request spec.
  if (ctx.out.spec instanceof Error) {
    return ctx.out.spec
  }

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

  if (!allowed(options.allow.method, ctx.spec.method)) {
    return ctx.error('spec_method_allow', 'Method "' + ctx.spec.method +
      '" not allowed by SDK option allow.method value: "' + options.allow.method + '"')
  }

  ctx.spec.params = prepareParams(ctx)
  ctx.spec.query = prepareQuery(ctx)
  ctx.spec.headers = prepareHeaders(ctx)

  if ('graphql' === point.kind) {
    // GraphQL addresses one endpoint: no path parts, no query string, and
    // the body carries the operation. prepareBody is skipped deliberately —
    // it only emits a body for data-input ops (create/update), whereas every
    // GraphQL op posts one, including load/list/remove.
    ctx.spec.body = utility.graphqlBody(ctx)
    ctx.spec.path = ''
    // prepareQuery already copied the op's match arguments into the query
    // string. Those same values are bound as operation variables, so leaving
    // them would send /graphql?id=i1 — duplicating the argument, leaking it
    // into the URL, and failing servers that reject unknown query params.
    ctx.spec.query = {}
    ctx.spec.headers['content-type'] = utility.GRAPHQL_CONTENT_TYPE
  }
  else {
    ctx.spec.body = prepareBody(ctx)
    ctx.spec.path = preparePath(ctx)
  }

  if (ctx.ctrl.explain) {
    ctx.ctrl.explain.spec = ctx.spec
  }

  // Whatever prepareAuth sets in the query, under whichever name, is the
  // credential; a key it leaves as it was is the caller's.
  const query = { ...ctx.spec.query }

  const spec = prepareAuth(ctx)

  if (!(spec instanceof Error)) {
    spec.authquery = Object.keys(spec.query || {})
      .filter((key) => spec.query[key] !== query[key])
    ctx.spec = spec
  }

  return spec
}

module.exports = {
  makeSpec
}
