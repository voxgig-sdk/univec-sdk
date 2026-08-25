// In-memory mock transport for testing without a live server. Serves the
// per-entity fixture data supplied via the test feature options (`entity`) and
// answers CRUD requests the way a REST server would. An optional `net` block
// layers deterministic network-behaviour simulation over the mock.

import Foundation

// THE MOCK HAS TO AGREE WITH THE MODEL. A point carrying
// `transform.res: `body.item`` describes an API that answers {"item": {...}},
// and the response transform unwraps that key on the way back. Returning the
// bare payload means the transform unwraps a property that is not there and
// the caller gets nothing. Mirrors the go/ts/lua/php mocks.
private func testEnvelope(_ ctx: Context, _ data: Value) -> Value {
  if case .noval = data { return data }
  if case .null = data { return data }
  guard let point = ctx.point else { return data }
  guard case .map(let tm)? = point.entries["transform"] else { return data }
  guard case .string(let spec)? = tm.entries["res"] else { return data }
  // Exactly `body.<key>`; a deeper path is not an envelope this mock can
  // synthesise, so it is left alone rather than guessed at.
  guard spec.hasPrefix("`body."), spec.hasSuffix("`"), spec.count >= 8 else { return data }
  let inner = String(spec.dropFirst(6).dropLast(1))
  guard !inner.isEmpty, !inner.contains(".") else { return data }
  let wrapped = VMap()
  wrapped.entries[inner] = data
  return .map(wrapped)
}

private func testRespond(_ ctx: Context, _ status: Int, _ data: Value, _ extra: VMap?) -> Value {
  let res = VMap()
  res.entries["status"] = .int(Int64(status))
  res.entries["statusText"] = .string("OK")
  let captured = testEnvelope(ctx, data)
  res.entries["json"] = .nat({ () -> Value in captured } as NativeCall0)
  res.entries["body"] = .string("not-used")
  if let extra = extra {
    for (k, v) in extra.entries { res.entries[k] = v }
  }
  return .map(res)
}

// For single-entity ops with an empty explicit match, fall back to the id the
// entity client already knows from a prior create/load.
private func testResolveMatch(_ ctx2: Context, _ explicitMatch: VMap) -> VMap {
  if explicitMatch.entries.count > 0 { return explicitMatch }
  for src in [ctx2.match, ctx2.data] {
    let v = gp(src, "id")
    if !isNil(v) && v != .string("__UNDEFINED__") {
      let m = VMap()
      m.entries["id"] = v
      return m
    }
  }
  return VMap()
}

private func testBuildArgs(_ ctx: Context, _ op: Operation, _ args: VMap?) -> Value {
  let opname = op.name

  let cfg: Value = ctx.config == nil ? .noval : .map(ctx.config!)
  let points = getpath(cfg, jtp("entity", ctx.entity!.getName(), "op", opname, "points"))

  // Pick the entity's own endpoint from config, not a cross-reference from
  // another resource that also returns it — the same rule makePoint falls
  // back to, so the seed-data query is built from the endpoint the request
  // will actually be sent to: a terminal `{id}` marks a record route, and
  // failing that the shallower path wins.
  func pointPartsLen(_ p: Value) -> Int {
    return getprop(p, .string("parts")).asList?.items.count ?? 0
  }
  func pointTerminalParam(_ p: Value) -> Bool {
    guard let items = getprop(p, .string("parts")).asList?.items, let last = items.last else {
      return false
    }
    return (last.asString ?? "").hasPrefix("{")
  }

  var point = getelem(points, .int(0))
  if let candidates = points.asList?.items {
    for cand in candidates {
      let candTerm = pointTerminalParam(cand)
      let bestTerm = pointTerminalParam(point)
      if candTerm != bestTerm {
        if candTerm { point = cand }
      }
      else if pointPartsLen(cand) < pointPartsLen(point) {
        point = cand
      }
    }
  }

  let paramsPath = getpath(point, jtp("args", "params"))
  let reqdParams = select(paramsPath, .map(vm(("reqd", .bool(true)))))
  let reqd = transform(reqdParams, jtp("`$EACH`", "", "`$KEY.name`"))

  let qand = VList()
  let q = VMap()
  q.entries["`$AND`"] = .list(qand)

  if let args = args {
    for key in keysof(.map(args)) {
      let isId = key == "id"
      let selected = select(reqd, .string(key))
      let isReqd = !isempty(selected)

      if isId || isReqd {
        let v = ctx.utility!.param(ctx, .string(key))
        let ka = gp(op.alias, key)

        let qor = VList()
        let qm1 = VMap()
        qm1.entries[key] = v
        qor.items.append(.map(qm1))
        if let kas = ka.asString {
          let qm2 = VMap()
          qm2.entries[kas] = v
          qor.items.append(.map(qm2))
        }

        let qorm = VMap()
        qorm.entries["`$OR`"] = .list(qor)
        qand.items.append(.map(qorm))
      }
    }
  }

  if let explain = ctx.ctrl.explain {
    let tm = VMap()
    tm.entries["query"] = .map(q)
    explain.entries["test"] = .map(tm)
  }

  return .map(q)
}

public final class TestFeature: BaseFeature {
  private var client: UnivecSDK?
  private var options: VMap?
  private var netcalls = 0

  public override init() {
    super.init()
    version = "0.0.1"
    name = "test"
    active = true
  }

  public override func initFeature(_ ctx: Context, _ options: VMap) {
    client = ctx.client
    self.options = options

    let entity = gp(options, "entity").asMap ?? VMap()

    client!.mode = "test"

    // Ensure entity ids are correct.
    _ = walk(.map(entity), { key, val, _, path in
      if path.count == 2, val.isMap, key.asString != nil {
        val.asMap!.entries["id"] = .string(strkey(key))
      }
      return val
    }, nil)

    let testFetcher: FetcherFunc = { ctx2, _fullurl, _fetchdef in
      let op = ctx2.op!
      let entmap = gp(entity, op.entity).asMap ?? VMap()

      if op.name == "load" {
        let args = testBuildArgs(ctx2, op, testResolveMatch(ctx2, ctx2.reqmatch))
        let found = select(.map(entmap), args)
        let ent = getelem(found, .int(0))
        if isNil(ent) {
          let extra = VMap()
          extra.entries["statusText"] = .string("Not found")
          return testRespond(ctx2, 404, .noval, extra)
        }
        delprop(ent, .string("$KEY"))
        return testRespond(ctx2, 200, clone(ent), nil)
      } else if op.name == "list" {
        let args = testBuildArgs(ctx2, op, ctx2.reqmatch)
        let found = select(.map(entmap), args)
        if isNil(found) {
          let extra = VMap()
          extra.entries["statusText"] = .string("Not found")
          return testRespond(ctx2, 404, .noval, extra)
        }
        if let fl = found.asList {
          for item in fl.items { delprop(item, .string("$KEY")) }
        }
        return testRespond(ctx2, 200, clone(found), nil)
      } else if op.name == "update" {
        var updateMatch = VMap()
        if let idv = ctx2.reqdata.entries["id"] {
          updateMatch.entries["id"] = idv
        }
        if let alias = op.alias, let aliasId = gp(alias, "id").asString,
          let av = ctx2.reqdata.entries[aliasId] {
          updateMatch.entries[aliasId] = av
        }
        if updateMatch.entries.count == 0 {
          updateMatch = testResolveMatch(ctx2, VMap())
        }
        let args = testBuildArgs(ctx2, op, updateMatch)
        let found = select(.map(entmap), args)
        var ent = getelem(found, .int(0))
        if isNil(ent) {
          for (_, e) in entmap.entries where e.isMap { ent = e; break }
        }
        if isNil(ent) {
          let extra = VMap()
          extra.entries["statusText"] = .string("Not found")
          return testRespond(ctx2, 404, .noval, extra)
        }
        if let entm = ent.asMap {
          for (k, v) in ctx2.reqdata.entries { entm.entries[k] = v }
        }
        delprop(ent, .string("$KEY"))
        return testRespond(ctx2, 200, clone(ent), nil)
      } else if op.name == "remove" {
        let args = testBuildArgs(ctx2, op, testResolveMatch(ctx2, ctx2.reqmatch))
        let found = select(.map(entmap), args)
        let ent = getelem(found, .int(0))
        if let entm2 = ent.asMap {
          let id = gp(entm2, "id")
          delprop(.map(entmap), id)
        }
        return testRespond(ctx2, 200, .noval, nil)
      } else if op.name == "create" {
        _ = testBuildArgs(ctx2, op, ctx2.reqdata)
        var id = ctx2.utility!.param(ctx2, .string("id"))
        if isNil(id) {
          id = .string(String(
            format: "%04x%04x%04x%04x",
            Int.random(in: 0..<0x10000), Int.random(in: 0..<0x10000),
            Int.random(in: 0..<0x10000), Int.random(in: 0..<0x10000)))
        }
        let ent = clone(.map(ctx2.reqdata))
        if let entm = ent.asMap {
          entm.entries["id"] = id
          if let idStr = id.asString { entmap.entries[idStr] = .map(entm) }
          delprop(.map(entm), .string("$KEY"))
          return testRespond(ctx2, 200, clone(.map(entm)), nil)
        }
        return testRespond(ctx2, 200, ent, nil)
      }

      let extra = VMap()
      extra.entries["statusText"] = .string("Unknown operation")
      return testRespond(ctx2, 404, .noval, extra)
    }

    // Optional network behaviour simulation over the mock transport.
    let net = gp(options, "net").asMap
    ctx.utility!.fetcher = net == nil ? testFetcher : makeNetsim(net!, testFetcher)
  }

  private func makeNetsim(_ net: VMap, _ inner: @escaping FetcherFunc) -> FetcherFunc {
    netcalls = 0

    func pickLatency() -> Int {
      let l = gp(net, "latency")
      if isNil(l) { return 0 }
      if let lm = l.asMap {
        let mn = foptInt(lm, "min", 0)
        let mx = foptInt(lm, "max", mn)
        if mx <= mn { return mn }
        return mn + ((mx - mn) >> 1)
      }
      let fixedMs = foptInt(net, "latency", 0)
      return fixedMs < 0 ? 0 : fixedMs
    }

    func sleepMs(_ ms: Int) {
      if ms <= 0 { return }
      foptSleep(net)(ms)
    }

    return { [weak self] ctx, url, fetchdef in
      guard let self = self else { return try inner(ctx, url, fetchdef) }
      self.netcalls += 1
      let call = self.netcalls

      if foptBool(net, "offline", false) {
        sleepMs(pickLatency())
        throw ctx.makeError("netsim_offline", "Simulated network offline (URL was: \"\(url)\")")
      }
      if call <= foptInt(net, "errorTimes", 0) {
        sleepMs(pickLatency())
        throw ctx.makeError("netsim_conn", "Simulated connection error (call \(call))")
      }
      if call <= foptInt(net, "failTimes", 0) {
        sleepMs(pickLatency())
        let status = foptInt(net, "failStatus", 503)
        let r = VMap()
        r.entries["status"] = .int(Int64(status))
        r.entries["statusText"] = .string("Simulated Failure")
        r.entries["body"] = .string("not-used")
        r.entries["json"] = .nat({ () -> Value in .noval } as NativeCall0)
        r.entries["headers"] = .map(VMap())
        return .map(r)
      }
      sleepMs(pickLatency())
      return try inner(ctx, url, fetchdef)
    }
  }
}
