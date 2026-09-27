
const CRED_name = 'authorization'

const OPTION_apikey = 'apikey'

const NOTFOUND = '__NOTFOUND__'

function prepareAuth(ctx) {
  const utility = ctx.utility

  const struct = utility.struct
  const getprop = struct.getprop
  const setprop = struct.setprop
  const delprop = struct.delprop

  const client = ctx.client
  const spec = ctx.spec

  if (null == spec) {
    return ctx.error('auth_no_spec', 'Expected context spec property to be defined.')
  }

  const headers = spec.headers

  const options = client.options()

  // Public APIs that need no auth omit the options.auth block entirely.
  if (null == options.auth) {
    delprop(headers, CRED_name)
    return spec
  }

  const apikey = getprop(options, OPTION_apikey, NOTFOUND)

  if (NOTFOUND === apikey || null == apikey || '' === apikey) {
    delprop(headers, CRED_name)
  }
  else {
    // Empty prefix (raw apiKey credential) must not add a leading space.
    setprop(headers, CRED_name,
      options.auth.prefix ? options.auth.prefix + ' ' + apikey : apikey)
  }

  return spec
}

module.exports = {
  prepareAuth
}
