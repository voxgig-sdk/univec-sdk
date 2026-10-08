
import {
  Content,
  File,
  Folder,
  cmp,
  isHttpBasicAuth,
  resolveAuthIn,
  resolveAuthName,
  resolveAuthPrefix,
} from '@voxgig/sdkgen'


import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'


const PrepareAuth = cmp(async function PrepareAuth(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const active = isAuthActive_js(model)
  const where = resolveAuthIn(model)
  const resolvedName = resolveAuthName(model)
  const name = 'header' === where ? resolvedName.toLowerCase() : resolvedName
  const prefix = resolveAuthPrefix(model)
  const basic = isHttpBasicAuth(model)

  Folder({ name: 'utility' }, () => {
    File({ name: 'PrepareAuthUtility.' + target.ext }, () => {
      Content(render({ active, where, name, prefix, basic }))
    })
  })
})


function render(spec: {
  active: boolean, where: string, name: string, prefix: string, basic: boolean
}): string {

  if (!spec.active) {
    return `
// This API declares no authentication, so there is no credential to
// place. The function stays in the pipeline because makeSpec calls it
// unconditionally.
function prepareAuth(ctx) {
  const spec = ctx.spec

  if (null == spec) {
    return ctx.error('auth_no_spec', 'Expected context spec property to be defined.')
  }

  return spec
}

module.exports = {
  prepareAuth
}
`
  }

  const preamble = `
const CRED_name = '${jsstr(spec.name)}'
${'cookie' === spec.where ? `
const { cookieKeep } = require('./PrepareHeadersUtility')

const COOKIE_header = 'cookie'
` : ''}
const OPTION_apikey = 'apikey'${spec.basic && 'header' === spec.where ? `
const OPTION_secret = 'secret'` : ''}

const NOTFOUND = '__NOTFOUND__'


// The client's \`auth.name\` option, when set, replaces the name the API declares.
function credName(name) {
  return 'string' === typeof name && '' !== name ? ${caseFold(spec.where, 'name')} : CRED_name
}


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

  const ${bag(spec.where)} = spec.${bag(spec.where)}
${cookieHelper(spec.where)}
  const options = client.options()

  // Public APIs that need no auth omit the options.auth block entirely.
  if (null == options.auth) {
    ${clear(spec.where, 'CRED_name')}
    return spec
  }

  const name = credName(options.auth.name)

  // A credential left under the declared name would travel beside the renamed one.
  if (CRED_name !== name) {
    ${clear(spec.where, 'CRED_name')}
  }

  const apikey = getprop(options, OPTION_apikey, NOTFOUND)
`

  // HTTP Basic is header-only by definition: the scheme is
  // `Authorization: Basic base64(user:pass)`. It cannot be expressed as a
  // query parameter or a cookie, so the branch is emitted only where it
  // can mean something.
  const basicBlock = (spec.basic && 'header' === spec.where) ? `
  // True HTTP Basic Auth joins the two credentials, base64-encoded - a single
  // token in the header (the branch below) can never authenticate against
  // an API that actually checks \`Authorization: Basic base64(user:pass)\`.
  // The password may be empty (RFC 7617): Lob, for one, documents the key as
  // the user with a blank password (\`curl -u key:\`).
  if (true === options.auth.basic) {
    const secret = getprop(options, OPTION_secret, NOTFOUND)
    const noApikey = NOTFOUND === apikey || null == apikey || '' === apikey
    const pass = NOTFOUND === secret || null == secret ? '' : secret

    if (noApikey) {
      delprop(headers, name)
    }
    else {
      const b64 = Buffer.from(apikey + ':' + pass).toString('base64')
      // The joined, encoded pair is a wire form neither credential's own
      // registration covers.
      utility.cleanAdd(ctx, b64)
      setprop(headers, name,
        options.auth.prefix ? options.auth.prefix + ' ' + b64 : b64)
    }

    return spec
  }
` : ''

  return preamble + basicBlock + `
  if (NOTFOUND === apikey || null == apikey || '' === apikey) {
    ${clear(spec.where, 'name')}
  }
  else {
${place(spec.where, 'name')}
  }

  return spec
}

module.exports = {
  prepareAuth
}
`
}


// The bag the credential lands in, per placement. Cookies ride the header
// bag because a cookie IS a header.
function bag(where: string): string {
  return 'query' === where ? 'query' : 'headers'
}


// Header names travel lower-cased; query and cookie names are case-sensitive.
function caseFold(where: string, expr: string): string {
  return 'header' === where ? expr + '.toLowerCase()' : expr
}


// A cookie has no header of its own: place() writes it into `cookie` as
// `name=value`, so clear() frees that pair, not a header of that name.
function clear(where: string, name: string): string {
  if ('query' === where) {
    return `delprop(query, ${name})`
  }

  if ('cookie' === where) {
    return `cookieSet(headers, ${name}, null)`
  }

  return `delprop(headers, ${name})`
}


// Splicing keeps the caller's other cookies and makes placement idempotent.
function cookieHelper(where: string): string {
  if ('cookie' !== where) {
    return ''
  }

  return `
  function cookieSet(headers, name, value) {
    const existing = getprop(headers, COOKIE_header, '')
    const kept = 'string' === typeof existing ? cookieKeep(existing, [name]) : []

    if (null != value) {
      kept.push(name + '=' + value)
    }

    if (0 === kept.length) {
      delprop(headers, COOKIE_header)
    }
    else {
      setprop(headers, COOKIE_header, kept.join('; '))
    }
  }
`
}


function place(where: string, name: string): string {
  if ('query' === where) {
    return `    setprop(query, ${name}, apikey)`
  }

  if ('cookie' === where) {
    return `    cookieSet(headers, ${name}, apikey)`
  }

  return `    // Empty prefix (raw apiKey credential) must not add a leading space.
    setprop(headers, ${name},
      options.auth.prefix ? options.auth.prefix + ' ' + apikey : apikey)`
}


function jsstr(s: string): string {
  return String(s).replace(/\\/g, '\\\\').replace(/'/g, "\\'")
}


export {
  PrepareAuth
}


function isAuthActive_js(model: any): boolean {
  const auth = getModelPath(model, `main.${KIT}.config.auth`,
    { only_active: false, required: false })
  return !(null != auth && false === auth.active)
}
