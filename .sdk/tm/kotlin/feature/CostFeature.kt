package KOTLINPACKAGE.feature

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.FetcherFn
import KOTLINPACKAGE.core.SdkClient
import KOTLINPACKAGE.utility.struct.Struct

// Cost tracking and spend budget. Uses BOTH seams, which is the point of the
// feature: money is spent per HTTP ATTEMPT (a retried call is charged again,
// because the upstream API charges it again), but it is owed by an
// OPERATION. So the transport wrap prices each attempt, and preDone
// attributes the running total to `<entity>.<op>` and to the caller
// (`ctrl.actor`, the same actor the audit feature records).
//
// The price of an attempt comes from the first source that answers: a
// response header (`header` x `perUnit`), the rate table (`rates`, keyed
// '<entity>.<op>' / '<op>' / '*'), then the flat `unit`. A body figure
// (`path` x `perUnit`, e.g. "usage.total_tokens") is read at preDone
// instead, from the already-parsed result. A body figure describes the whole
// call, so it REPLACES the per-attempt estimate rather than adding to it.
//
// `budget` caps total spend. With `onBudget` = "deny" a further operation is
// refused at prePoint, before an endpoint is resolved and before anything
// reaches the network.
//
// ORDER MATTERS. Cost must sit INSIDE the cache, or a response served from
// cache is charged for money that was never spent.
@Suppress("UNCHECKED_CAST")
class CostFeature : BaseFeature("cost", "0.0.1", true) {

  private var client: SdkClient? = null
  private var options: MutableMap<String, Any?>? = null
  private var seq = 0

  // Aggregates (mirrors the ts client._cost record).
  var currency = "USD"
  var total = CostTotal()
  var ops: MutableMap<String, CostBucket> = linkedMapOf()
  var actors: MutableMap<String, CostBucket> = linkedMapOf()
  var budget = CostBudget()
  var last: CostRecord? = null

  class CostBucket {
    var calls = 0
    var amount = 0.0
  }

  class CostTotal {
    var calls = 0
    var attempts = 0
    var amount = 0.0
    var reported = 0.0
    var estimated = 0.0
  }

  class CostBudget {
    var limit = 0.0
    var spent = 0.0
    var remaining = 0.0
    var exceeded = false
  }

  class CostRecord {
    var seq = 0
    var entity = ""
    var op = ""
    var actor = ""
    var amount = 0.0
    var currency = ""
    var source = ""
    var attempts = 0
  }

  // Per-operation accumulator. Held in ctx.out for the life of one call, the
  // same place metrics keeps its start marker.
  class CostPending {
    var attempts = 0
    var amount = 0.0
    var reported = 0.0
    var estimated = 0.0
    var source = "none"

    // Set by prePoint. Its absence means the call never entered the pipeline
    // (direct/graphql), so charge commits the spend itself.
    var piped = false
  }

  override fun init(ctx: Context, options: MutableMap<String, Any?>) {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)
    this.seq = 0

    this.currency = FeatureOptions.foptStr(options, "currency", "USD")
    this.total = CostTotal()
    this.ops = linkedMapOf()
    this.actors = linkedMapOf()
    this.budget = CostBudget()
    this.budget.limit = limit()
    this.budget.remaining = this.budget.limit
    this.last = null

    if (!this.active) {
      return
    }

    val inner: FetcherFn = ctx.utility!!.fetcher

    ctx.utility!!.fetcher = { ctx2, url, fetchdef -> charge(ctx2, url, fetchdef, inner) }
  }

  // Budget gate. Runs before endpoint resolution, so a refused call costs
  // nothing at all.
  override fun prePoint(ctx: Context) {
    if (!this.active) {
      return
    }

    // Mark the context as running through the pipeline, so charge knows a
    // preDone is coming and does not commit the spend itself.
    val pending = pending(ctx)
    pending.piped = true

    val lim = limit()
    if (lim <= 0) {
      return
    }

    if (this.total.amount < lim) {
      return
    }

    this.budget.exceeded = true

    if ("deny" != FeatureOptions.foptStr(this.options, "onBudget", "warn")) {
      return
    }

    val err = ctx.makeError(
      "cost_budget",
      "Cost budget of " + lim + " " + this.currency + " is spent (" +
        this.total.amount + " " + this.currency + " used)",
    )

    // Short-circuit endpoint resolution; makePoint surfaces this error
    // before any network activity.
    ctx.out["point"] = err
  }

  private fun charge(
    ctx: Context,
    url: String,
    fetchdef: MutableMap<String, Any?>,
    inner: FetcherFn,
  ): Any? {
    var res: Any? = null
    var err: RuntimeException? = null

    // A throwing transport still costs an attempt. Without this, a run of
    // connection-level failures under `retry` (which catches the throw and
    // tries again) would be charged nothing at all, and an onBudget = "deny"
    // ceiling could never stop it.
    try {
      res = inner(ctx, url, fetchdef)
    } catch (e: RuntimeException) {
      err = e
    }

    val priced = price(ctx, res)
    val amount = priced.first
    val source = priced.second

    val pending = pending(ctx)
    pending.attempts++

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
    if ("header" == source || "body" == source) {
      pending.reported += amount
    } else {
      pending.estimated += amount
    }
    pending.source = source

    this.total.attempts++

    // direct() and graphql() reach the transport without dispatching any
    // pipeline hooks - no prePoint to gate on, and no preDone to commit.
    // Their spend is committed here instead, or it would never be counted
    // and could run past an onBudget = "deny" ceiling indefinitely. `piped`
    // is set by prePoint, so its absence is the signal.
    if (!pending.piped) {
      commit(ctx, pending, "_", "direct")
      ctx.out.remove(COST_PENDING_KEY)
    }

    if (err != null) {
      throw err
    }

    return res
  }

  private fun pending(ctx: Context): CostPending {
    val raw = ctx.out[COST_PENDING_KEY]
    if (raw is CostPending) {
      return raw
    }
    val pending = CostPending()
    ctx.out[COST_PENDING_KEY] = pending
    return pending
  }

  // Attribute the operation's spend once the call is finished.
  override fun preDone(ctx: Context) {
    finish(ctx, true)
  }

  // A failed operation still spent the money. When the pipeline errors,
  // preDone never runs, so without this the attempts are counted and the
  // spend is not, and a budget could never see the cost of a failed call.
  // Whichever hook fires first consumes the pending entry, so it commits
  // exactly once.
  override fun preUnexpected(ctx: Context) {
    finish(ctx, false)
  }

  private fun finish(ctx: Context, done: Boolean) {
    if (!this.active) {
      return
    }
    val raw = ctx.out[COST_PENDING_KEY]
    if (raw !is CostPending) {
      return
    }
    ctx.out.remove(COST_PENDING_KEY)

    // A FAILED operation that made no attempt never reached the network:
    // prePoint creates the pending entry to mark the context as piped, and
    // then the budget gate refuses the call (rbac, or an unresolvable
    // endpoint, short-circuits just as early). Committing it would count a
    // call that never happened and file a zero-amount record as `last`.
    //
    // A SUCCEEDED operation that made no attempt is the opposite case: it
    // was served from the cache. That is a real call, and the fact that it
    // cost nothing is the whole point of ordering cost inside the cache.
    if (!done && 0 == raw.attempts) {
      return
    }

    val entity = if ("" == ctx.op.entity) "_" else ctx.op.entity
    val opname = if ("" == ctx.op.name) "_" else ctx.op.name

    commit(ctx, raw, entity, opname)
  }

  // Commit one operation's spend: totals, budget, per-op and per-actor
  // attribution, and the record. Shared by finish and the raw-request path
  // in charge, which has no preDone to reach.
  private fun commit(ctx: Context, pending: CostPending, entity: String, opname: String) {
    var amount = pending.amount
    var reported = pending.reported
    var estimated = pending.estimated
    var source = pending.source

    // A body figure prices the whole call, so it replaces the per-attempt
    // estimate rather than adding to it - and, being server-stated, the
    // whole amount counts as reported.
    val body = bodyAmount(ctx)
    if (body != null) {
      amount = body
      reported = body
      estimated = 0.0
      source = "body"
    }

    spend(amount, reported, estimated)

    var actor = "anonymous"
    val optActor = FeatureOptions.foptStr(this.options, "actor", "")
    if ("" != optActor) {
      actor = optActor
    }
    if ("" != ctx.ctrl.actor) {
      actor = ctx.ctrl.actor
    }

    this.total.calls++
    bump(this.ops, "$entity.$opname", amount)
    bump(this.actors, actor, amount)

    this.seq++
    val record = CostRecord()
    record.seq = this.seq
    record.entity = entity
    record.op = opname
    record.actor = actor
    record.amount = amount
    record.currency = this.currency
    record.source = source
    record.attempts = pending.attempts
    this.last = record

    val sink = this.options?.get("sink")
    if (sink is java.util.function.Consumer<*>) {
      try {
        (sink as java.util.function.Consumer<CostRecord>).accept(record)
      } catch (e: RuntimeException) {
        // A sink must never break the call it is reporting on.
      }
    }
  }

  // Price one attempt: a reported header figure, else the rate table, else
  // the flat unit.
  private fun price(ctx: Context, res: Any?): Pair<Double, String> {
    val header = FeatureOptions.foptStr(this.options, "header", "")
    if ("" != header) {
      val v = headerNum(res, header)
      if (v != null) {
        return Pair(v * perUnit(), "header")
      }
    }

    val rate = rate(ctx)
    if (rate != null) {
      return Pair(rate, "table")
    }

    val unit = FeatureOptions.foptNum(this.options, "unit", 0.0)
    if (0.0 != unit) {
      return Pair(unit, "unit")
    }

    return Pair(0.0, "none")
  }

  // The rate table uses the same lookup grammar as rbac's rules:
  // '<entity>.<op>', then '<op>', then '*'.
  private fun rate(ctx: Context): Double? {
    val rates = FeatureOptions.foptMap(this.options, "rates") ?: return null

    val entity = if (ctx.entity != null) ctx.entity!!.name else ctx.op.entity
    val opname = ctx.op.name

    for (key in arrayOf("$entity.$opname", opname, "*")) {
      val r = rates[key]
      if (r is Number) {
        return r.toDouble()
      }
    }
    return null
  }

  // A usage figure from the parsed result body, priced by perUnit. Read
  // here, not at the transport seam, because the body is consumed once.
  private fun bodyAmount(ctx: Context): Double? {
    val path = FeatureOptions.foptStr(this.options, "path", "")
    if ("" == path) {
      return null
    }
    val body = ctx.result?.body as? Map<String, Any?> ?: return null
    val v = Struct.getpath(body, path) ?: return null
    if (v !is Number) {
      return null
    }
    return v.toDouble() * perUnit()
  }

  private fun spend(amount: Double, reported: Double, estimated: Double) {
    this.total.amount += amount
    this.total.reported += reported
    this.total.estimated += estimated

    this.budget.spent = this.total.amount
    if (this.budget.limit > 0) {
      this.budget.remaining = Math.max(0.0, this.budget.limit - this.total.amount)
      if (this.total.amount >= this.budget.limit) {
        this.budget.exceeded = true
      }
    } else {
      this.budget.remaining = 0.0
    }
  }

  private fun bump(bucket: MutableMap<String, CostBucket>, key: String, amount: Double) {
    var b = bucket[key]
    if (b == null) {
      b = CostBucket()
      bucket[key] = b
    }
    b.calls++
    b.amount += amount
  }

  // HTTP header names are case-insensitive and a custom transport keeps
  // conventional casing ("X-Request-Cost"), so fresHeader scans rather than
  // indexes.
  private fun headerNum(res: Any?, name: String): Double? {
    val v = FeatureOptions.fresHeader(res, name)
    if ("" == v) {
      return null
    }
    return try {
      v.trim().toDouble()
    } catch (e: RuntimeException) {
      null
    }
  }

  private fun perUnit(): Double {
    return FeatureOptions.foptNum(this.options, "perUnit", 0.0)
  }

  private fun limit(): Double {
    return FeatureOptions.foptNum(this.options, "budget", 0.0)
  }

  companion object {
    private const val COST_PENDING_KEY = "cost_pending"
  }
}
