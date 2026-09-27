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

  let apikey = getprop(.map(options), .string(optionApikey), .string(notFound))

  var skip = isNil(apikey)
  if let apikeyStr = apikey.asString, apikeyStr == notFound || apikeyStr == "" {
    skip = true
  }
${basicBlock(spec)}
  if skip {
    headers.entries.removeValue(forKey: headerAuth)
  } else {
    var authPrefix = ""
    if let ap = gpath(options, "auth", "prefix").asString { authPrefix = ap }
    let apikeyVal = apikey.asString ?? ""
    // Empty prefix (raw apiKey credential) must not add a leading space.
    headers.entries[headerAuth] = .string(authPrefix == "" ? apikeyVal : authPrefix + " " + apikeyVal)
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
  // True HTTP Basic Auth needs TWO credentials, base64-joined - a single
  // token in the header (the branch below) can never authenticate against
  // an API that actually checks \`Authorization: Basic base64(user:pass)\`.
  if true == gpath(options, "auth", "basic").asBool {
    let secret = getprop(.map(options), .string(optionSecret), .string(notFound))

    var noSecret = isNil(secret)
    if let secretStr = secret.asString, secretStr == notFound || secretStr == "" {
      noSecret = true
    }

    if skip || noSecret {
      headers.entries.removeValue(forKey: headerAuth)
    } else {
      var authPrefix = ""
      if let ap = gpath(options, "auth", "prefix").asString { authPrefix = ap }
      let joined = (apikey.asString ?? "") + ":" + (secret.asString ?? "")
      let b64 = Data(joined.utf8).base64EncodedString()
      // Empty prefix (raw credential) must not add a leading space.
      headers.entries[headerAuth] = .string(authPrefix == "" ? b64 : authPrefix + " " + b64)
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

  let apikey = getprop(.map(options), .string(optionApikey), .string(notFound))

  var skip = isNil(apikey)
  if let apikeyStr = apikey.asString, apikeyStr == notFound || apikeyStr == "" {
    skip = true
  }

  if skip {
    query.entries.removeValue(forKey: queryAuth)
  } else {
    let apikeyVal = apikey.asString ?? ""
    // NO PREFIX IN A QUERY STRING. \`?${spec.name}=Bearer%20abc\` is not a
    // thing any API reads: the prefix is a header convention, so it is
    // dropped here deliberately rather than silently concatenated.
    query.entries[queryAuth] = .string(apikeyVal)
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

// The cookie header minus our own pair, every other cookie untouched.
private func cookiesWithoutCred(_ headers: VMap) -> String {
  guard let existing = headers.entries[cookieHeader]?.asString, existing != "" else {
    return ""
  }

  var kept: [String] = []
  for part in existing.split(separator: ";", omittingEmptySubsequences: false) {
    let piece = part.trimmingCharacters(in: .whitespaces)
    if piece == "" || piece == cookieAuth || piece.hasPrefix(cookieAuth + "=") {
      continue
    }
    kept.append(piece)
  }

  return kept.joined(separator: "; ")
}

// Set (non-nil) or remove (nil) our pair, leaving every other cookie in
// place. Deleting the whole header to remove one pair would drop cookies
// this SDK never set.
private func applyCookie(_ headers: VMap, _ value: String?) {
  let rest = cookiesWithoutCred(headers)

  guard let value = value else {
    if rest == "" {
      headers.entries.removeValue(forKey: cookieHeader)
    } else {
      headers.entries[cookieHeader] = .string(rest)
    }
    return
  }

  let pair = cookieAuth + "=" + value
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
    applyCookie(headers, nil)
    return spec
  }

  let apikey = getprop(.map(options), .string(optionApikey), .string(notFound))

  var skip = isNil(apikey)
  if let apikeyStr = apikey.asString, apikeyStr == notFound || apikeyStr == "" {
    skip = true
  }

  if skip {
    applyCookie(headers, nil)
  } else {
    // NO PREFIX IN A COOKIE either - a cookie carries a bare \`name=value\`
    // pair, not a header's scheme-prefixed credential.
    applyCookie(headers, apikey.asString ?? "")
  }

  return spec
}
`
}


export {
  PrepareAuth
}
