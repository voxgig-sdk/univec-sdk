
function makeUrl(ctx) {
  const utility = ctx.utility
  const spec = ctx.spec
  const result = ctx.result

  const struct = utility.struct
  const escurl = struct.escurl
  const escre = struct.escre
  const join = struct.join
  const items = struct.items

  if (null == spec) {
    return ctx.error('url_no_spec', 'Expected context spec property to be defined.')
  }

  if (null == result) {
    return ctx.error('url_no_result', 'Expected context result property to be defined.')
  }

  let url = join([spec.base, spec.prefix, spec.path, spec.suffix], '/', true)

  // A route the definition ends with a slash keeps it: a server such as a
  // Django REST one redirects or refuses the route without it.
  const orig = ctx.point && ctx.point.orig
  if ('string' === typeof orig && orig.endsWith('/') && !spec.suffix && !url.endsWith('/')) {
    url += '/'
  }
  let resmatch = {}

  // Sent with the request, never recorded as the entity's match.
  const authquery = spec.authquery || []

  const params = spec.params

  for (let [key, val] of items(params)) {
    if (null != val) {
      url = url.replace(RegExp('{' + escre(key) + '}'), escurl(val))
      resmatch[key] = val
    }
  }

  // A placeholder left in the route would send the request to the wrong route.
  // The base's own placeholders are server variables, resolved with the options.
  const base = ('string' === typeof spec.base ? spec.base : '').replace(/\/+$/, '')
  const route = url.startsWith(base) ? url.slice(base.length) : url
  const unfilled = route.match(/\{[^{}\/]+\}/g)
  if (null != unfilled) {
    return ctx.error('url_param_missing', 'URL path has no value for ' + unfilled.join(', ') + '.')
  }

  let qsep = '?'
  for (let [key, val] of items(spec.query)) {
    if (null != val) {
      url += qsep + escurl(key) + '=' + escurl(val)
      qsep = '&'
      if (!authquery.includes(key)) {
        resmatch[key] = val
      }
    }
  }

  result.resmatch = resmatch

  return url
}

module.exports = {
  makeUrl
}
