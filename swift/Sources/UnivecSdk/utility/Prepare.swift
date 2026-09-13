// Univec SDK utility: request preparation steps (method, path, params,
// query, headers, body, auth) plus param resolution.

import Foundation

private let methodMap: [String: String] = [
  "create": "POST",
  "update": "PUT",
  "load": "GET",
  "list": "GET",
  "remove": "DELETE",
  "patch": "PATCH",
]

func prepareMethodUtil(_ ctx: Context) -> String {
  let opname = ctx.op!.name

  // The API definition is authoritative: a POST-only or PATCH-based API
  // exposes `update` as POST or PATCH, not the PUT the op name implies.
  // Only fall back to the op-name convention when the point has no method.
  if let pm = gp(ctx.point, "method").asString, !pm.isEmpty {
    return pm.uppercased()
  }

  // No default: an op name outside the convention resolves to NO method,
  // exactly as the ts reference (`methodMap[key]` is undefined there) and
  // go's "" spelling of the same no-value. The silent-pass inline runner
  // hid a stray "GET" fallback here; the shared corpus (prepareMethod,
  // opname "bad" -> null) pins it now.
  return methodMap[opname] ?? ""
}

func preparePathUtil(_ ctx: Context) -> String {
  let parts = gp(ctx.point, "parts").asList ?? VList()
  return join(.list(parts), "/", true)
}

func prepareHeadersUtil(_ ctx: Context) -> VMap {
  let options = ctx.client!.optionsMap()
  let headers = gp(options, "headers")
  if isNil(headers) { return VMap() }
  return clone(headers).asMap ?? VMap()
}

func prepareParamsUtil(_ ctx: Context) -> VMap {
  let utility = ctx.utility!
  var paramdefs: VList = VList()
  if let argsMap = gp(ctx.point, "args").asMap, let pl = gp(argsMap, "params").asList {
    paramdefs = pl
  }

  let prepared = VMap()
  for pd in paramdefs.items {
    let val = utility.param(ctx, pd)
    if !isNil(val), let pdm = pd.asMap {
      let name = gp(pdm, "name").asString ?? ""
      if name != "" { prepared.entries[name] = val }
    }
  }
  return prepared
}

func prepareQueryUtil(_ ctx: Context) -> VMap {
  let reqmatch = ctx.reqmatch

  var paramnames: VList = VList()
  if let pl = gp(ctx.point, "params").asList { paramnames = pl }

  let query = VMap()
  for item in items(.map(reqmatch)) {
    let key = item[0].asString ?? ""
    let val = item[1]
    if !isNil(val) && !containsStr(paramnames, key) {
      query.entries[key] = val
    }
  }
  return query
}

private func containsStr(_ list: VList, _ s: String) -> Bool {
  return list.items.contains { $0.asString == s }
}

func prepareBodyUtil(_ ctx: Context) -> Value {
  let op = ctx.op!
  if op.input == "data" {
    return ctx.utility!.transformRequest(ctx)
  }
  return .noval
}

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

func paramUtil(_ ctx: Context, _ paramdef: Value) -> Value {
  let point = ctx.point
  let spec = ctx.spec
  let match = ctx.match
  let reqmatch = ctx.reqmatch
  let data = ctx.data
  let reqdata = ctx.reqdata

  let pt = typify(paramdef)

  let key: String
  if 0 < (T_string & pt) {
    key = paramdef.asString ?? ""
  } else {
    key = gp(paramdef, "name").asString ?? ""
  }

  var akey = ""
  if let alias = gp(point, "alias").asMap, let ak = gp(alias, key).asString {
    akey = ak
  }

  var val = gp(reqmatch, key)
  if isNil(val) { val = gp(match, key) }

  if isNil(val) && akey != "" {
    if let sp = spec { sp.alias.entries[akey] = .string(key) }
    val = gp(reqmatch, akey)
  }

  if isNil(val) { val = gp(reqdata, key) }
  if isNil(val) { val = gp(data, key) }

  if isNil(val) && akey != "" {
    val = gp(reqdata, akey)
    if isNil(val) { val = gp(data, akey) }
  }

  return val
}
