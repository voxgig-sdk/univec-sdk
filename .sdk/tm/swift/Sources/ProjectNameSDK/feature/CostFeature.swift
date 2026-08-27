// Cost tracking and spend budget. Uses BOTH seams, which is the point of
// the feature: money is spent per HTTP ATTEMPT (a retried call is charged
// again, because the upstream API charges it again), but it is owed by an
// OPERATION. So the transport wrap prices each attempt, and preDone
// attributes the running total to `<entity>.<op>` and to the caller
// (`ctrl.actor`, the same actor the audit feature records).
//
// The price of an attempt comes from the first source that answers: a
// response header (`header` x `perUnit`), the rate table (`rates`, keyed
// '<entity>.<op>' / '<op>' / '*'), then the flat `unit`. A body figure
// (`path` x `perUnit`, e.g. "usage.total_tokens") is read at preDone
// instead, from the already-parsed result. A body figure describes the
// whole call, so it REPLACES the per-attempt estimate rather than adding
// to it.
//
// `budget` caps total spend. With `onBudget` = "deny" a further operation
// is refused at prePoint, before an endpoint is resolved and before
// anything reaches the network.
//
// ORDER MATTERS. Cost must sit INSIDE the cache, or a response served from
// cache is charged for money that was never spent.

import Foundation

public final class CostBucket {
  public var calls = 0
  public var amount: Double = 0
  public init() {}
}

public final class CostTotal {
  public var calls = 0
  public var attempts = 0
  public var amount: Double = 0
  public var reported: Double = 0
  public var estimated: Double = 0
  public init() {}
}

public final class CostBudget {
  public var limit: Double = 0
  public var spent: Double = 0
  public var remaining: Double = 0
  public var exceeded = false
  public init() {}
}

public final class CostRecord {
  public var seq = 0
  public var entity = ""
  public var op = ""
  public var actor = ""
  public var amount: Double = 0
  public var currency = ""
  public var source = ""
  public var attempts = 0
  public init() {}
}

// Per-operation accumulator. Held in ctx.out for the life of one call, the
// same place metrics keeps its start marker.
public final class CostPending {
  public var attempts = 0
  public var amount: Double = 0
  public var reported: Double = 0
  public var estimated: Double = 0
  public var source = "none"

  // Set by prePoint. Its absence means the call never entered the pipeline
  // (direct/graphql), so charge commits the spend itself.
  public var piped = false
  public init() {}
}

public final class CostFeature: BaseFeature {
  private var client: UnivecSDK?
  private var options: VMap?
  private var seq = 0

  // Aggregates (mirrors the ts client._cost record).
  public var currency = "USD"
  public var total = CostTotal()
  public var ops: [String: CostBucket] = [:]
  public var actors: [String: CostBucket] = [:]
  public var budget = CostBudget()
  public var last: CostRecord?

  private static let pendingKey = "cost_pending"

  public override init() {
    super.init()
    version = "0.0.1"
    name = "cost"
    active = true
  }

  public override func initFeature(_ ctx: Context, _ options: VMap) {
    client = ctx.client
    self.options = options
    active = foptBool(options, "active", false)
    seq = 0

    currency = foptStr(options, "currency", "USD")
    total = CostTotal()
    ops = [:]
    actors = [:]
    budget = CostBudget()
    budget.limit = limitValue()
    budget.remaining = budget.limit
    last = nil

    if !active {
      return
    }

    let inner = ctx.utility!.fetcher!

    ctx.utility!.fetcher = { ctx2, url, fetchdef in
      try self.charge(ctx2, url, fetchdef, inner)
    }
  }

  // Budget gate. Runs before endpoint resolution, so a refused call costs
  // nothing at all.
  public override func prePoint(_ ctx: Context) {
    if !active {
      return
    }

    // Mark the context as running through the pipeline, so charge knows a
    // preDone is coming and does not commit the spend itself.
    let pending = pendingFor(ctx)
    pending.piped = true

    let lim = limitValue()
    if lim <= 0 {
      return
    }
    if total.amount < lim {
      return
    }

    budget.exceeded = true

    if foptStr(options, "onBudget", "warn") != "deny" {
      return
    }

    let err = ctx.makeError("cost_budget",
      "Cost budget of \(lim) \(currency) is spent (\(total.amount) \(currency) used)")

    // Short-circuit endpoint resolution; makePoint surfaces this error
    // before any network activity.
    ctx.out["point"] = err
  }

  private func charge(_ ctx: Context, _ url: String, _ fetchdef: VMap,
                      _ inner: FetcherFunc) throws -> Value {
    var res: Value = .noval
    var err: Error? = nil

    // A throwing transport still costs an attempt. Without this, a run of
    // connection-level failures under `retry` (which catches the throw and
    // tries again) would be charged nothing at all, and an onBudget =
    // "deny" ceiling could never stop it.
    do {
      res = try inner(ctx, url, fetchdef)
    } catch {
      err = error
    }

    let (amount, source) = price(ctx, res)

    let pending = pendingFor(ctx)
    pending.attempts += 1

    // Accumulated here, committed once at preDone. Adding each attempt to
    // the running total and then subtracting it again when a body figure
    // supersedes it loses precision to catastrophic cancellation
    // (5 + (0.01 - 5) is not 0.01 in binary floating point).
    //
    // Reported and estimated are kept apart per ATTEMPT, not per operation:
    // a 503 priced from the rate table followed by a 200 carrying the cost
    // header is part estimate, part reported, and collapsing both into the
    // final attempt's category would corrupt the split.
    pending.amount += amount
    if source == "header" || source == "body" {
      pending.reported += amount
    } else {
      pending.estimated += amount
    }
    pending.source = source

    total.attempts += 1

    // direct() and graphql() reach the transport without dispatching any
    // pipeline hooks - no prePoint to gate on, and no preDone to commit.
    // Their spend is committed here instead, or it would never be counted
    // and could run past an onBudget = "deny" ceiling indefinitely. `piped`
    // is set by prePoint, so its absence is the signal.
    if !pending.piped {
      commit(ctx, pending, "_", "direct")
      ctx.out.removeValue(forKey: CostFeature.pendingKey)
    }

    if let err = err {
      throw err
    }

    return res
  }

  private func pendingFor(_ ctx: Context) -> CostPending {
    if let existing = ctx.out[CostFeature.pendingKey] as? CostPending {
      return existing
    }
    let pending = CostPending()
    ctx.out[CostFeature.pendingKey] = pending
    return pending
  }

  // Attribute the operation's spend once the call is finished.
  public override func preDone(_ ctx: Context) {
    finish(ctx, true)
  }

  // A failed operation still spent the money. When the pipeline errors,
  // preDone never runs, so without this the attempts are counted and the
  // spend is not, and a budget could never see the cost of a failed call.
  // Whichever hook fires first consumes the pending entry, so it commits
  // exactly once.
  public override func preUnexpected(_ ctx: Context) {
    finish(ctx, false)
  }

  private func finish(_ ctx: Context, _ done: Bool) {
    if !active {
      return
    }
    guard let pending = ctx.out[CostFeature.pendingKey] as? CostPending else {
      return
    }
    ctx.out.removeValue(forKey: CostFeature.pendingKey)

    // A FAILED operation that made no attempt never reached the network:
    // prePoint creates the pending entry to mark the context as piped, and
    // then the budget gate refuses the call (rbac, or an unresolvable
    // endpoint, short-circuits just as early). Committing it would count a
    // call that never happened and file a zero-amount record as `last`.
    //
    // A SUCCEEDED operation that made no attempt is the opposite case: it
    // was served from the cache. That is a real call, and the fact that it
    // cost nothing is the whole point of ordering cost inside the cache.
    if !done && pending.attempts == 0 {
      return
    }

    var entity = ctx.op?.entity ?? "_"
    var opname = ctx.op?.name ?? "_"
    if entity == "" {
      entity = "_"
    }
    if opname == "" {
      opname = "_"
    }

    commit(ctx, pending, entity, opname)
  }

  // Commit one operation's spend: totals, budget, per-op and per-actor
  // attribution, and the record. Shared by finish and the raw-request path
  // in charge, which has no preDone to reach.
  private func commit(_ ctx: Context, _ pending: CostPending,
                      _ entity: String, _ opname: String) {
    var amount = pending.amount
    var reported = pending.reported
    var estimated = pending.estimated
    var source = pending.source

    // A body figure prices the whole call, so it replaces the per-attempt
    // estimate rather than adding to it - and, being server-stated, the
    // whole amount counts as reported.
    if let body = bodyAmount(ctx) {
      amount = body
      reported = body
      estimated = 0
      source = "body"
    }

    spend(amount, reported, estimated)

    var actor = "anonymous"
    let optActor = foptStr(options, "actor", "")
    if optActor != "" {
      actor = optActor
    }
    if ctx.ctrl.actor != "" {
      actor = ctx.ctrl.actor
    }

    total.calls += 1
    bump(&ops, entity + "." + opname, amount)
    bump(&actors, actor, amount)

    seq += 1
    let record = CostRecord()
    record.seq = seq
    record.entity = entity
    record.op = opname
    record.actor = actor
    record.amount = amount
    record.currency = currency
    record.source = source
    record.attempts = pending.attempts
    last = record

    // A sink must never break the call it is reporting on, so it is a
    // non-throwing closure rather than a `throws` one.
    if let sink = fopt(options, "sink").asNative as? (CostRecord) -> Void {
      sink(record)
    }
  }

  // Price one attempt: a reported header figure, else the rate table, else
  // the flat unit.
  private func price(_ ctx: Context, _ res: Value) -> (Double, String) {
    let header = foptStr(options, "header", "")
    if header != "", let v = headerNum(res, header) {
      return (v * perUnit(), "header")
    }

    if let rate = rateFor(ctx) {
      return (rate, "table")
    }

    let unit = foptNum(options, "unit", 0)
    if unit != 0 {
      return (unit, "unit")
    }

    return (0, "none")
  }

  // The rate table uses the same lookup grammar as rbac's rules:
  // '<entity>.<op>', then '<op>', then '*'.
  private func rateFor(_ ctx: Context) -> Double? {
    guard let rates = foptMap(options, "rates") else {
      return nil
    }

    let entity = ctx.entity?.getName() ?? ctx.op?.entity ?? ""
    let opname = ctx.op?.name ?? ""

    for key in [entity + "." + opname, opname, "*"] {
      if let n = gp(rates, key).asDouble {
        return n
      }
    }
    return nil
  }

  // A usage figure from the parsed result body, priced by perUnit. Read
  // here, not at the transport seam, because the body is consumed once.
  private func bodyAmount(_ ctx: Context) -> Double? {
    let path = foptStr(options, "path", "")
    if path == "" {
      return nil
    }
    guard let result = ctx.result, result.body.asMap != nil else {
      return nil
    }
    let v = getpath(result.body, jtpv(path.split(separator: ".").map(String.init)))
    guard let n = v.asDouble else {
      return nil
    }
    return n * perUnit()
  }

  private func spend(_ amount: Double, _ reported: Double, _ estimated: Double) {
    total.amount += amount
    total.reported += reported
    total.estimated += estimated

    budget.spent = total.amount
    if budget.limit > 0 {
      budget.remaining = max(0, budget.limit - total.amount)
      if total.amount >= budget.limit {
        budget.exceeded = true
      }
    } else {
      budget.remaining = 0
    }
  }

  private func bump(_ bucket: inout [String: CostBucket], _ key: String, _ amount: Double) {
    let b: CostBucket
    if let existing = bucket[key] {
      b = existing
    } else {
      b = CostBucket()
      bucket[key] = b
    }
    b.calls += 1
    b.amount += amount
  }

  // HTTP header names are case-insensitive and a custom transport keeps
  // conventional casing ("X-Request-Cost"), so fresHeader scans rather than
  // indexes.
  private func headerNum(_ res: Value, _ name: String) -> Double? {
    let (v, has) = fresHeader(res, name)
    if !has {
      return nil
    }
    return Double(v.trimmingCharacters(in: .whitespaces))
  }

  private func perUnit() -> Double {
    foptNum(options, "perUnit", 0)
  }

  private func limitValue() -> Double {
    foptNum(options, "budget", 0)
  }
}
