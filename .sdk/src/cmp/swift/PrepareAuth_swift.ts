import {
  Content,
  File,
  Folder,
  cmp,
  isAuthSuppressed,
  isHttpBasicAuth,
  resolveAuthIn,
  resolveAuthName,
  resolveAuthPrefix,
} from '@voxgig/sdkgen'


import { swiftString, swiftTargetDir } from './utility_swift'


const PrepareAuth = cmp(async function PrepareAuth(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const suppressed = isAuthSuppressed(model)

  const where = resolveAuthIn(model)

  const resolvedName = resolveAuthName(model)
  const name = 'header' === where ? resolvedName.toLowerCase() : resolvedName

  const prefix = resolveAuthPrefix(model)

  const basic = isHttpBasicAuth(model)

  Folder({ name: 'Sources' }, () => {
    Folder({ name: swiftTargetDir(model) }, () => {
      Folder({ name: 'utility' }, () => {
        File({ name: 'PrepareAuth.' + target.ext }, () => {
          Content(render({
            Name: model.const.Name,
            suppressed, where, name, prefix, basic,
          }))
        })
      })
    })
  })
})


type AuthSpec = {
  Name: string
  suppressed: boolean
  where: string
  name: string
  prefix: string
  basic: boolean
}


function render(spec: AuthSpec): string {
  const head = `// ${spec.Name} SDK utility: prepareAuth - place the API credential.
//
// GENERATED, not templated: WHERE the credential goes - header, query or
// cookie, and under what name - is a fact about THIS API, and tm/ can only
// hold one answer. Extracted from utility/Prepare.swift, which keeps the
// seven prepare* functions that do not depend on the model. Bound by
// utility/Register.swift (\`u.prepareAuth = prepareAuthUtil\`) exactly as
// before: same module, same internal symbol, no import needed.
//
// See cmp/swift/PrepareAuth_swift.ts.

import Foundation
`

  if (spec.suppressed) {
    return head + `
// This SDK is configured with authentication OFF
// (main.kit.config.auth.active is false), so there is no credential to
// place. The function stays in the pipeline because Register binds it
// unconditionally and makeSpec calls it on every request.
func prepareAuthUtil(_ ctx: Context) throws -> Spec {
  guard let spec = ctx.spec else {
    throw ctx.makeError("auth_no_spec", "Expected context spec property to be defined.")
  }

  return spec
}
`
  }

  if ('query' === spec.where) return head + renderQuery(spec)
  if ('cookie' === spec.where) return head + renderCookie(spec)

  return head + renderHeader(spec)
}


function renderHeader(spec: AuthSpec): string {
  const basicConst = spec.basic ? `
private let optionSecret = "secret"` : ''

  return `
private let headerAuth = ${swiftString(spec.name)}
private let optionApikey = "apikey"${basicConst}
private let notFound = "__NOTFOUND__"
${authName('headerAuth', true)}
func prepareAuthUtil(_ ctx: Context) throws -> Spec {
  guard let spec = ctx.spec else {
    throw ctx.makeError("auth_no_spec", "Expected context spec property to be defined.")
  }

  let headers = spec.headers
  let options = ctx.client!.optionsMap()

  // Public APIs that need no auth omit the options.auth block entirely.
  let auth = getprop(.map(options), .string("auth"))
  if isNil(auth) {
    headers.entries.removeValue(forKey: headerAuth)
    return spec
  }

  let name = prepareAuthName(options)

  // A credential left under the declared name would travel beside the renamed one.
  if name != headerAuth {
    headers.entries.removeValue(forKey: headerAuth)
  }

  let apikey = getprop(.map(options), .string(optionApikey), .string(notFound))

  var skip = isNil(apikey)
  if let apikeyStr = apikey.asString, apikeyStr == notFound || apikeyStr == "" {
    skip = true
  }
${basicBlock(spec)}
  if skip {
    headers.entries.removeValue(forKey: name)
  } else {
    var authPrefix = ""
    if let ap = gpath(options, "auth", "prefix").asString { authPrefix = ap }
    let apikeyVal = apikey.asString ?? ""
    // Empty prefix (raw apiKey credential) must not add a leading space.
    headers.entries[name] = .string(authPrefix == "" ? apikeyVal : authPrefix + " " + apikeyVal)
  }

  return spec
}
`
}


// HTTP Basic is header-only BY DEFINITION: the scheme is
// `Authorization: Basic base64(user:pass)`. It cannot be expressed as a
// query parameter or a cookie, so the branch is emitted only where it can
// mean something — and only when the model says the scheme IS basic, so an
// ordinary bearer SDK carries no dead code and regenerates unchanged.
function basicBlock(spec: AuthSpec): string {
  if (!spec.basic) return ''

  return `
  // True HTTP Basic Auth joins the two credentials, base64-encoded - a single
  // token in the header (the branch below) can never authenticate against
  // an API that actually checks \`Authorization: Basic base64(user:pass)\`.
  // The password may be empty (RFC 7617): Lob, for one, documents the key as
  // the user with a blank password (\`curl -u key:\`).
  if true == gpath(options, "auth", "basic").asBool {
    let secret = getprop(.map(options), .string(optionSecret), .string(notFound))

    var noSecret = isNil(secret)
    if let secretStr = secret.asString, secretStr == notFound || secretStr == "" {
      noSecret = true
    }

    if skip {
      headers.entries.removeValue(forKey: name)
    } else {
      var authPrefix = ""
      if let ap = gpath(options, "auth", "prefix").asString { authPrefix = ap }
      let joined = (apikey.asString ?? "") + ":" + (noSecret ? "" : (secret.asString ?? ""))
      let b64 = Data(joined.utf8).base64EncodedString()
      // The joined, encoded pair is a wire form neither credential's own
      // registration covers.
      ctx.utility!.cleanAdd(ctx, .string(b64))
      // Empty prefix (raw credential) must not add a leading space.
      headers.entries[name] = .string(authPrefix == "" ? b64 : authPrefix + " " + b64)
    }

    return spec
  }
`
}


function renderQuery(spec: AuthSpec): string {
  return `
private let queryAuth = ${swiftString(spec.name)}
private let optionApikey = "apikey"
private let notFound = "__NOTFOUND__"
${authName('queryAuth', false)}
func prepareAuthUtil(_ ctx: Context) throws -> Spec {
  guard let spec = ctx.spec else {
    throw ctx.makeError("auth_no_spec", "Expected context spec property to be defined.")
  }

  let query = spec.query
  let options = ctx.client!.optionsMap()

  // Public APIs that need no auth omit the options.auth block entirely.
  let auth = getprop(.map(options), .string("auth"))
  if isNil(auth) {
    query.entries.removeValue(forKey: queryAuth)
    return spec
  }

  let name = prepareAuthName(options)

  // A credential left under the declared name would travel beside the renamed one.
  if name != queryAuth {
    query.entries.removeValue(forKey: queryAuth)
  }

  let apikey = getprop(.map(options), .string(optionApikey), .string(notFound))

  var skip = isNil(apikey)
  if let apikeyStr = apikey.asString, apikeyStr == notFound || apikeyStr == "" {
    skip = true
  }

  if skip {
    query.entries.removeValue(forKey: name)
  } else {
    let apikeyVal = apikey.asString ?? ""
    // NO PREFIX IN A QUERY STRING. \`?${spec.name}=Bearer%20abc\` is not a
    // thing any API reads: the prefix is a header convention, so it is
    // dropped here deliberately rather than silently concatenated.
    query.entries[name] = .string(apikeyVal)
  }

  return spec
}
`
}


function renderCookie(spec: AuthSpec): string {
  return `
private let cookieHeader = "cookie"
private let cookieAuth = ${swiftString(spec.name)}
private let optionApikey = "apikey"
private let notFound = "__NOTFOUND__"
${authName('cookieAuth', false)}
// The cookie header minus the named pair, every other cookie untouched.
private func cookiesWithoutCred(_ headers: VMap, _ name: String) -> String {
  guard let existing = headers.entries[cookieHeader]?.asString, existing != "" else {
    return ""
  }

  return cookieKeep(existing, [name]).joined(separator: "; ")
}

// Set (non-nil) or remove (nil) the named pair, leaving every other cookie
// in place. Deleting the whole header to remove one pair would drop cookies
// this SDK never set.
private func applyCookie(_ headers: VMap, _ name: String, _ value: String?) {
  let rest = cookiesWithoutCred(headers, name)

  guard let value = value else {
    if rest == "" {
      headers.entries.removeValue(forKey: cookieHeader)
    } else {
      headers.entries[cookieHeader] = .string(rest)
    }
    return
  }

  let pair = name + "=" + value
  headers.entries[cookieHeader] = .string(rest == "" ? pair : rest + "; " + pair)
}

func prepareAuthUtil(_ ctx: Context) throws -> Spec {
  guard let spec = ctx.spec else {
    throw ctx.makeError("auth_no_spec", "Expected context spec property to be defined.")
  }

  let headers = spec.headers
  let options = ctx.client!.optionsMap()

  // Public APIs that need no auth omit the options.auth block entirely.
  let auth = getprop(.map(options), .string("auth"))
  if isNil(auth) {
    applyCookie(headers, cookieAuth, nil)
    return spec
  }

  let name = prepareAuthName(options)

  // A credential left under the declared name would travel beside the renamed one.
  if name != cookieAuth {
    applyCookie(headers, cookieAuth, nil)
  }

  let apikey = getprop(.map(options), .string(optionApikey), .string(notFound))

  var skip = isNil(apikey)
  if let apikeyStr = apikey.asString, apikeyStr == notFound || apikeyStr == "" {
    skip = true
  }

  if skip {
    applyCookie(headers, name, nil)
  } else {
    // NO PREFIX IN A COOKIE either - a cookie carries a bare \`name=value\`
    // pair, not a header's scheme-prefixed credential.
    applyCookie(headers, name, apikey.asString ?? "")
  }

  return spec
}
`
}


// The client's `auth.name` option, when set, replaces the declared name; a
// header name travels lower-cased.
function authName(declared: string, header: boolean): string {
  return `
// The client's auth.name option, when set, replaces the name the API declares.
private func prepareAuthName(_ options: VMap) -> String {
  if let name = gpath(options, "auth", "name").asString, name != "" {
    return ${header ? 'name.lowercased()' : 'name'}
  }
  return ${declared}
}
`
}


export {
  PrepareAuth
}
