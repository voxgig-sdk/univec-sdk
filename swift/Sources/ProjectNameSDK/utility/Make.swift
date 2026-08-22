// Univec SDK utility: the operation pipeline stages - point resolution,
// spec/url/fetchdef construction, transport request, and response/result
// shaping.

import Foundation

func makePointUtil(_ ctx: Context) throws -> VMap? {
  if let stored = ctx.out["point"], let sp = stored {
    // A PrePoint feature hook (e.g. rbac) may short-circuit the operation by
    // storing an error here; surface it before any endpoint resolution.
    if let err = sp as? Error { throw err }
    if let tm = sp as? VMap { ctx.point = tm; return tm }
  }

  let op = ctx.op!
  let options = ctx.options

  let allowOp = gpath(options, "allow", "op").asString ?? ""
  if !allowOp.contains(op.name) {
    throw ctx.makeError("point_op_allow",
      "Operation \"\(op.name)\" not allowed by SDK option allow.op value: \"\(allowOp)\"")
  }

  if op.points.isEmpty {
    throw ctx.makeError("point_no_points",
      "Operation \"\(op.name)\" has no endpoint definitions.")
  }

  if op.points.count == 1 {
    ctx.point = op.points[0]
  } else {
    let reqselector: VMap
    let selector: VMap
    if op.input == "data" {
      reqselector = ctx.reqdata
      selector = ctx.data
    } else {
      reqselector = ctx.reqmatch
      selector = ctx.match
    }

    var point: VMap? = nil
    var matched = false
    for candidate in op.points {
      let selectDef = gp(candidate, "select").asMap
      var found = true

      if let selectDef = selectDef {
        if let existList = gp(selectDef, "exist").asList {
          for ek in existList.items {
            let existkey = ek.asString ?? ""
            let rv = getprop(.map(reqselector), .string(existkey))
            let sv = getprop(.map(selector), .string(existkey))
            if isNil(rv) && isNil(sv) { found = false; break }
          }
        }
      }

      if found {
        let reqAction = gp(reqselector, "$action")
        let selectAction = gp(selectDef == nil ? .noval : .map(selectDef!), "$action")
        if reqAction != selectAction { found = false }
      }

      if found {
        point = candidate
        matched = true
        break
      }
    }

    // select.exist can list more than the params needed to pick a point (for
    // /boards/{id} it is Trello's 17 optional query-includes), so a plain
    // {id} call matches NOTHING. Fall back to the entity's own route rather
    // than whichever point came last.
    if !matched {
      // A request naming an action reaches here only because that action's
      // own point failed its exist test, so it is unbuildable whatever we
      // pick. Refuse it BEFORE choosing a fallback: the guard below compares
      // the chosen point's $action and would wave the request through
      // whenever the fallback lands on the action point itself.
      let unmatchedAction = gp(reqselector, "$action")
      if !isNil(unmatchedAction) {
        throw ctx.makeError("point_action_invalid",
          "Operation \"\(op.name)\" action \"\(stringify(unmatchedAction))\" is not valid.")
      }

      // A terminal parameter marks a record route (/boards/{id}); a
      // cross-reference ends in the relationship's name (/posts/{id}/author).
      // Failing that, the shallower path wins. The same rule runs at
      // generation time, in helpers/opShape.ts — both sides must move
      // together.
      func partsLen(_ p: VMap) -> Int {
        return gp(p, "parts").asList?.items.count ?? 0
      }
      func terminalParam(_ p: VMap) -> Bool {
        guard let items = gp(p, "parts").asList?.items, let last = items.last else {
          return false
        }
        return (last.asString ?? "").hasPrefix("{")
      }

      point = op.points.first
      for candidate in op.points {
        guard let best = point else { break }
        let candTerm = terminalParam(candidate)
        let bestTerm = terminalParam(best)
        if candTerm != bestTerm {
          if candTerm { point = candidate }
        }
        else if partsLen(candidate) < partsLen(best) {
          point = candidate
        }
      }
    }

    let reqAction = gp(reqselector, "$action")
    if !isNil(reqAction), let point = point {
      let pointSelect = gp(point, "select").asMap
      let pointAction = gp(pointSelect == nil ? .noval : .map(pointSelect!), "$action")
      if reqAction != pointAction {
        throw ctx.makeError("point_action_invalid",
          "Operation \"\(op.name)\" action \"\(stringify(reqAction))\" is not valid.")
      }
    }

    ctx.point = point
  }

  return ctx.point
}

func makeSpecUtil(_ ctx: Context) throws -> Spec {
  if let cached = ctx.out["spec"] as? Spec {
    ctx.spec = cached
    return cached
  }

  let options = ctx.options
  let utility = ctx.utility!

  let basev = gp(options, "base").asString ?? ""
  let prefix = gp(options, "prefix").asString ?? ""
  let suffix = gp(options, "suffix").asString ?? ""
  let parts = gp(ctx.point, "parts").asList

  let specmap = VMap()
  specmap.entries["base"] = .string(basev)
  specmap.entries["prefix"] = .string(prefix)
  specmap.entries["parts"] = parts == nil ? .noval : .list(parts!)
  specmap.entries["suffix"] = .string(suffix)
  specmap.entries["step"] = .string("start")

  ctx.spec = Spec(specmap)
  ctx.spec!.method = utility.prepareMethod(ctx)

  let allowMethod = gpath(options, "allow", "method").asString ?? ""
  if !allowMethod.contains(ctx.spec!.method) {
    throw ctx.makeError("spec_method_allow",
      "Method \"\(ctx.spec!.method)\" not allowed by SDK option allow.method value: \"\(allowMethod)\"")
  }

  ctx.spec!.params = utility.prepareParams(ctx)
  ctx.spec!.query = utility.prepareQuery(ctx)
  ctx.spec!.headers = utility.prepareHeaders(ctx)

  if "graphql" == gp(ctx.point, "kind").asString {
    // GraphQL addresses one endpoint: no path parts, no query string, and
    // the body carries the operation. prepareBody is skipped deliberately —
    // it only emits a body for data-input ops, whereas every GraphQL op
    // posts one, including load/list/remove.
    ctx.spec!.body = utility.graphqlBody(ctx)
    ctx.spec!.path = ""
    // prepareQuery already copied the op's match arguments into the query
    // string. Those same values are bound as operation variables, so
    // leaving them would send /graphql?id=i1.
    ctx.spec!.query = VMap()
    ctx.spec!.headers.entries["content-type"] = .string(graphqlContentType)
  }
  else {
    ctx.spec!.body = utility.prepareBody(ctx)
    ctx.spec!.path = utility.preparePath(ctx)
  }

  if let explain = ctx.ctrl.explain {
    explain.entries["spec"] = .nat(ctx.spec!)
  }

  let spec = try utility.prepareAuth(ctx)
  ctx.spec = spec
  return spec
}

func makeUrlUtil(_ ctx: Context) throws -> String {
  guard let spec = ctx.spec else {
    throw ctx.makeError("url_no_spec", "Expected context spec property to be defined.")
  }
  guard let result = ctx.result else {
    throw ctx.makeError("url_no_result", "Expected context result property to be defined.")
  }

  var url = join(jtp(spec.base, spec.prefix, spec.path, spec.suffix), "/", true)
  let resmatch = VMap()

  for item in items(.map(spec.params)) {
    let key = item[0].asString ?? ""
    let val = item[1]
    if !isNil(val) {
      let pattern = "\\{" + escre(.string(key)) + "\\}"
      url = regexReplace(url, pattern, escurl(.string(stringify(val))))
      resmatch.entries[key] = val
    }
  }

  var qsep = "?"
  for item in items(.map(spec.query)) {
    let key = item[0].asString ?? ""
    let val = item[1]
    if !isNil(val) {
      url += qsep + escurl(.string(key)) + "=" + escurl(.string(stringify(val)))
      qsep = "&"
      resmatch.entries[key] = val
    }
  }

  result.resmatch = resmatch
  return url
}

func makeFetchDefUtil(_ ctx: Context) throws -> VMap {
  guard let spec = ctx.spec else {
    throw ctx.makeError("fetchdef_no_spec", "Expected context spec property to be defined.")
  }

  if ctx.result == nil { ctx.result = Result(nil) }

  spec.step = "prepare"

  let url = try ctx.utility!.makeUrl(ctx)
  spec.url = url

  let fetchdef = VMap()
  fetchdef.entries["url"] = .string(url)
  fetchdef.entries["method"] = .string(spec.method)
  fetchdef.entries["headers"] = .map(spec.headers)

  if !isNil(spec.body) {
    if spec.body.isMap {
      fetchdef.entries["body"] = .string(jsonify(spec.body, indent: 0))
    } else {
      fetchdef.entries["body"] = spec.body
    }
  }

  return fetchdef
}

func makeRequestUtil(_ ctx: Context) throws -> Response {
  if let cached = ctx.out["request"] as? Response { return cached }

  let utility = ctx.utility!

  var response = Response(nil)
  let result = Result(nil)
  ctx.result = result

  guard let spec = ctx.spec else {
    throw ctx.makeError("request_no_spec", "Expected context spec property to be defined.")
  }

  let fetchdef: VMap
  do {
    fetchdef = try utility.makeFetchDef(ctx)
  } catch {
    response.err = error
    ctx.response = response
    spec.step = "postrequest"
    return response
  }

  if let explain = ctx.ctrl.explain {
    explain.entries["fetchdef"] = .map(fetchdef)
  }

  spec.step = "prerequest"

  let url = gp(fetchdef, "url").asString ?? ""

  var fetched: Value = .noval
  var fetchErr: Error? = nil
  do {
    fetched = try utility.fetcher(ctx, url, fetchdef)
  } catch {
    fetchErr = error
  }

  if let fe = fetchErr {
    response.err = fe
  } else if isNil(fetched) {
    let m = VMap()
    m.entries["err"] = .nat(ctx.makeError("request_no_response", "response: undefined"))
    response = Response(m)
  } else if let fm = fetched.asMap {
    response = Response(fm)
  } else {
    response.err = ctx.makeError("request_invalid_response", "response: invalid type")
  }

  spec.step = "postrequest"
  ctx.response = response
  return response
}

func makeResponseUtil(_ ctx: Context) throws -> Response {
  if let cached = ctx.out["response"] as? Response { return cached }

  let utility = ctx.utility!

  guard let spec = ctx.spec else {
    throw ctx.makeError("response_no_spec", "Expected context spec property to be defined.")
  }
  guard let response = ctx.response else {
    throw ctx.makeError("response_no_response", "Expected context response property to be defined.")
  }
  guard let result = ctx.result else {
    throw ctx.makeError("response_no_result", "Expected context result property to be defined.")
  }

  spec.step = "response"

  _ = utility.resultBasic(ctx)
  _ = utility.resultHeaders(ctx)
  _ = utility.resultBody(ctx)

  // GraphQL reports failures as a top-level `errors` array under HTTP 200,
  // so resultBasic's status check never sees them. Lift them here, before
  // the response transform tries to unwrap data that is not there.
  _ = utility.graphqlErrors(ctx)

  _ = utility.transformResponse(ctx)

  if result.err == nil {
    result.ok = true
  }

  if let explain = ctx.ctrl.explain {
    explain.entries["result"] = .nat(result)
  }

  return response
}

func makeResultUtil(_ ctx: Context) throws -> Result {
  if let cached = ctx.out["result"] as? Result { return cached }

  let op = ctx.op!
  let entity = ctx.entity

  guard let spec = ctx.spec else {
    throw ctx.makeError("result_no_spec", "Expected context spec property to be defined.")
  }
  guard let result = ctx.result else {
    throw ctx.makeError("result_no_result", "Expected context result property to be defined.")
  }

  spec.step = "result"

  _ = ctx.utility!.transformResponse(ctx)

  if op.name == "list" {
    let resdata = result.resdata
    result.resdata = .list([])

    if let list = resdata.asList, list.items.count > 0, let entity = entity {
      let entities = VList()
      for entry in list.items {
        let ent = entity.make()
        if let entryMap = entry.asMap {
          ent.data(.map(entryMap))
        }
        entities.items.append(.nat(ent))
      }
      result.resdata = .list(entities)
    }
  }

  if let explain = ctx.ctrl.explain {
    explain.entries["result"] = .nat(result)
  }

  return result
}
