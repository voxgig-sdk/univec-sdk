// Univec SDK utility: prepareAuth - place the API credential.
//
// GENERATED, not templated: WHERE the credential goes - header, query or
// cookie, and under what name - is a fact about THIS API, and tm/ can only
// hold one answer. Extracted from utility/Prepare.swift, which keeps the
// seven prepare* functions that do not depend on the model. Bound by
// utility/Register.swift (`u.prepareAuth = prepareAuthUtil`) exactly as
// before: same module, same internal symbol, no import needed.
//
// See cmp/swift/PrepareAuth_swift.ts.

import Foundation

private let headerAuth = "authorization"
private let optionApikey = "apikey"
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
