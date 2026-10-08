// Univec SDK utility: request preparation steps (method, path, params,
// query, headers, body) plus param resolution. The auth step is GENERATED
// into utility/PrepareAuth.swift - see the note below.

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

// The arguments a point declares in one location, query or header, each with
// the name it travels under and the value this call passes in its match or
// else its data. Unlike a path parameter, the entity's stored match and data
// never supply one.
func callArgs(_ ctx: Context, _ kind: String) -> [(name: String, wire: String, val: Value)] {
  var out: [(name: String, wire: String, val: Value)] = []
  guard let defs = gpath(ctx.point, "args", kind).asList else { return out }
  for ad in defs.items {
    guard let name = gp(ad, "name").asString, !name.isEmpty else { continue }
    let orig = gp(ad, "orig").asString ?? ""
    var val = gp(ctx.reqmatch, name)
    if isNil(val) { val = gp(ctx.reqdata, name) }
    out.append((name: name, wire: orig.isEmpty ? name : orig, val: val))
  }
  return out
}

func prepareHeadersUtil(_ ctx: Context) -> VMap {
  let options = ctx.client!.optionsMap()
  let headers = gp(options, "headers")
  let out = mediaHeaders(ctx.point, isNil(headers) ? VMap() : (clone(headers).asMap ?? VMap()))

  // A header argument replaces a default of the same name, whatever its case.
  for arg in callArgs(ctx, "header") where !isNil(arg.val) {
    let key = arg.wire.lowercased()
    for k in out.entries.keys where k.lowercased() == key {
      _ = out.entries.removeValue(forKey: k)
    }
    out.entries[key] = .string(stringify(arg.val))
  }

  // A cookie argument travels in the cookie header, form serialized and
  // percent-encoded, replacing a cookie of the same name among those the
  // caller's headers already send.
  let sent = callArgs(ctx, "cookie").filter { !isNil($0.val) }
  if !sent.isEmpty {
    let names = sent.flatMap { arg in
      arg.val.asMap != nil ? keysof(arg.val).map { escurl(.string($0)) } : [arg.wire]
    }
    var kept: [String] = []
    for k in out.entries.keys where k.lowercased() == "cookie" {
      if let given = out.entries[k]?.asString { kept.append(contentsOf: cookieKeep(given, names)) }
      _ = out.entries.removeValue(forKey: k)
    }
    for arg in sent {
      let pair = cookiePair(arg.wire, arg.val)
      if !pair.isEmpty { kept.append(pair) }
    }
    if !kept.isEmpty { out.entries["cookie"] = .string(kept.joined(separator: "; ")) }
  }
  return out
}

// The form style of a cookie parameter: a list repeats the name, a map sends
// its own keys, and every value is percent-encoded.
private func cookiePair(_ wire: String, _ val: Value) -> String {
  let esc = { (v: Value) in escurl(.string(stringify(v))) }
  var pairs: [String] = []
  if let items = val.asList?.items {
    for item in items { pairs.append(wire + "=" + esc(item)) }
  } else if let entries = val.asMap?.entries {
    for key in keysof(val) { pairs.append(escurl(.string(key)) + "=" + esc(entries[key] ?? .null)) }
  } else {
    pairs.append(wire + "=" + esc(val))
  }
  return pairs.joined(separator: "; ")
}

// The caller's cookie pieces with the named cookies removed: a cookie is one
// ;-delimited piece, whatever its value holds.
func cookieKeep(_ header: String, _ names: [String]) -> [String] {
  var kept: [String] = []
  for piece in header.split(separator: ";", omittingEmptySubsequences: false) {
    let cookie = piece.trimmingCharacters(in: .whitespaces)
    let name = cookie.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    if !cookie.isEmpty && !names.contains(name) { kept.append(cookie) }
  }
  return kept
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

  var paramnames: [Value] = []
  if let pl = gp(ctx.point, "params").asList { paramnames.append(contentsOf: pl.items) }
  // A path parameter travels in the path. The generated config lists them as
  // args.params, which prepareParams reads; params is the older list of names.
  if let apl = gpath(ctx.point, "args", "params").asList {
    for pd in apl.items {
      paramnames.append(gp(pd, "name"))
    }
  }
  // A header or cookie parameter travels in the headers, which prepareHeaders
  // fills, unless a query parameter shares its name: then both are sent.
  var declared: [Value] = []
  if let dql = gpath(ctx.point, "args", "query").asList {
    for qd in dql.items {
      declared.append(gp(qd, "name"))
    }
  }
  for located in [gpath(ctx.point, "args", "header"), gpath(ctx.point, "args", "cookie")] {
    guard let defs = located.asList else { continue }
    for hd in defs.items {
      let name = gp(hd, "name")
      if let s = name.asString, !containsStr(declared, s) {
        paramnames.append(name)
      }
    }
  }

  // A query parameter travels under the name the definition gives it, its
  // orig, which the model may have renamed for the caller.
  var wire: [String: String] = [:]
  if let aql = gpath(ctx.point, "args", "query").asList {
    for qd in aql.items {
      if let name = gp(qd, "name").asString, let orig = gp(qd, "orig").asString, !orig.isEmpty {
        wire[name] = orig
      }
    }
  }

  let query = VMap()
  for item in items(.map(reqmatch)) {
    let key = item[0].asString ?? ""
    let val = item[1]
    if !isNil(val) && "$action" != key && !containsStr(paramnames, key) {
      query.entries[wire[key] ?? key] = val
    }
  }

  // A create or update passes its query arguments in its data.
  for arg in callArgs(ctx, "query") where !isNil(arg.val) && !containsStr(paramnames, arg.name) {
    query.entries[arg.wire] = arg.val
  }
  return query
}

private func containsStr(_ list: [Value], _ s: String) -> Bool {
  return list.contains { $0.asString == s }
}

func prepareBodyUtil(_ ctx: Context) -> Value {
  let op = ctx.op!
  if op.input == "data" {
    if isRawRequest(ctx.point) { return rawBodyOf(ctx.reqdata) }
    return ctx.utility!.transformRequest(ctx)
  }
  return .noval
}

// prepareAuth IS NOT HERE. It was, and it hardcoded
//
//   private let headerAuth = "authorization"
//
// WHERE THE CREDENTIAL GOES IS A FACT ABOUT THE API - header, query or
// cookie, and under what name - and apidef resolves it into
// main.kit.info.security. A template can only hold one answer, so an
// apiKey-in-query API (joplin's `?token=`) got an Authorization header it
// does not read and never got the query parameter it does.
//
// So `prepareAuthUtil` is GENERATED, into utility/PrepareAuth.swift beside
// this file, by cmp/swift/PrepareAuth_swift.ts. Same module, same internal
// symbol, so utility/Register.swift still binds it with
// `u.prepareAuth = prepareAuthUtil` and nothing else moved. Declaring it
// here as well would be an "invalid redeclaration" that fails the whole
// SwiftPM target.
//
// The seven functions above and paramUtil below do not depend on the model,
// so they stay templated, and so does the lookup it shares with makePoint.

func paramUtil(_ ctx: Context, _ paramdef: Value) -> Value {
  let pt = typify(paramdef)

  let key: String
  if 0 < (T_string & pt) {
    key = paramdef.asString ?? ""
  } else {
    key = gp(paramdef, "name").asString ?? ""
  }

  let akey = paramAlias(ctx.point, key)
  if let sp = ctx.spec, akey != "", isNil(gp(ctx.reqmatch, key)), isNil(gp(ctx.match, key)) {
    sp.alias.entries[akey] = .string(key)
  }

  return paramValue(ctx, ctx.point, key)
}

// The name a point gives a parameter in the call, if it renames it.
private func paramAlias(_ point: VMap?, _ key: String) -> String {
  if let alias = gp(point, "alias").asMap, let ak = gp(alias, key).asString {
    return ak
  }
  return ""
}

// The value the call or its entity gives a point's parameter, under its name
// or the point's alias for it.
func paramValue(_ ctx: Context, _ point: VMap?, _ key: String) -> Value {
  let akey = paramAlias(point, key)

  var val = gp(ctx.reqmatch, key)
  if isNil(val) { val = gp(ctx.match, key) }
  if isNil(val) && akey != "" { val = gp(ctx.reqmatch, akey) }
  if isNil(val) { val = gp(ctx.reqdata, key) }
  if isNil(val) { val = gp(ctx.data, key) }

  if isNil(val) && akey != "" {
    val = gp(ctx.reqdata, akey)
    if isNil(val) { val = gp(ctx.data, akey) }
  }

  return val
}
