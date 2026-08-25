package SCALAPACKAGE.feature

import java.util.{LinkedHashMap, Map => JMap}
import SCALAPACKAGE.core.{Context, FetcherFn, SdkClient}
import SCALAPACKAGE.utility.struct.Struct

// Public per-key aggregate. Tests read `f.ops.get(key).calls`, `.amount`.
class CostBucket {
  var calls: Int = 0
  var amount: Double = 0.0
}

class CostTotal {
  var calls: Int = 0
  var attempts: Int = 0
  var amount: Double = 0.0
  var reported: Double = 0.0
  var estimated: Double = 0.0
}

class CostBudget {
  var limit: Double = 0.0
  var spent: Double = 0.0
  var remaining: Double = 0.0
  var exceeded: Boolean = false
}

class CostRecord {
  var seq: Int = 0
  var entity: String = ""
  var op: String = ""
  var actor: String = ""
  var amount: Double = 0.0
  var currency: String = ""
  var source: String = ""
  var attempts: Int = 0
}

// Per-operation accumulator. Held in ctx.out for the life of one call, the
// same place metrics keeps its start marker.
class CostPending {
  var attempts: Int = 0
  var amount: Double = 0.0
  var reported: Double = 0.0
  var estimated: Double = 0.0
  var source: String = "none"

  // Set by prePoint. Its absence means the call never entered the pipeline
  // (direct/graphql), so charge commits the spend itself.
  var piped: Boolean = false
}

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
class CostFeature extends BaseFeature("cost", "0.0.1", true) {

  private var client: SdkClient = null
  private var options: JMap[String, Object] = null
  private var seq: Int = 0

  // Aggregates (mirrors the ts client._cost record).
  var currency: String = "USD"
  var total: CostTotal = new CostTotal()
  var ops: JMap[String, CostBucket] = new LinkedHashMap[String, CostBucket]()
  var actors: JMap[String, CostBucket] = new LinkedHashMap[String, CostBucket]()
  var budget: CostBudget = new CostBudget()
  var last: CostRecord = null

  private val COST_PENDING_KEY = "cost_pending"

  override def init(ctx: Context, options: JMap[String, Object]): Unit = {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)
    this.seq = 0

    this.currency = FeatureOptions.foptStr(options, "currency", "USD")
    this.total = new CostTotal()
    this.ops = new LinkedHashMap[String, CostBucket]()
    this.actors = new LinkedHashMap[String, CostBucket]()
    this.budget = new CostBudget()
    this.budget.limit = limit()
    this.budget.remaining = this.budget.limit
    this.last = null

    if (!this.active) return

    val inner: FetcherFn = ctx.utility.fetcher
    ctx.utility.fetcher = (ctx2, url, fetchdef) => charge(ctx2, url, fetchdef, inner)
  }

  // Budget gate. Runs before endpoint resolution, so a refused call costs
  // nothing at all.
  override def prePoint(ctx: Context): Unit = {
    if (!this.active) return

    // Mark the context as running through the pipeline, so charge knows a
    // preDone is coming and does not commit the spend itself.
    val pending = pendingFor(ctx)
    pending.piped = true

    val lim = limit()
    if (lim <= 0) return
    if (this.total.amount < lim) return

    this.budget.exceeded = true

    if (!"deny".equals(FeatureOptions.foptStr(this.options, "onBudget", "warn"))) return

    val err = ctx.makeError("cost_budget",
      "Cost budget of " + lim + " " + this.currency + " is spent (" +
        this.total.amount + " " + this.currency + " used)")

    // Short-circuit endpoint resolution; makePoint surfaces this error
    // before any network activity.
    ctx.out.put("point", err)
  }

  private def charge(ctx: Context, url: String, fetchdef: JMap[String, Object],
                     inner: FetcherFn): Object = {
    var res: Object = null
    var err: RuntimeException = null

    // A throwing transport still costs an attempt. Without this, a run of
    // connection-level failures under `retry` (which catches the throw and
    // tries again) would be charged nothing at all, and an onBudget = "deny"
    // ceiling could never stop it.
    try res = inner(ctx, url, fetchdef)
    catch { case e: RuntimeException => err = e }

    val priced = price(ctx, res)
    val amount = priced._1
    val source = priced._2

    val pending = pendingFor(ctx)
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
    if ("header".equals(source) || "body".equals(source)) pending.reported += amount
    else pending.estimated += amount
    pending.source = source

    this.total.attempts += 1

    // direct() and graphql() reach the transport without dispatching any
    // pipeline hooks - no prePoint to gate on, and no preDone to commit.
    // Their spend is committed here instead, or it would never be counted
    // and could run past an onBudget = "deny" ceiling indefinitely. `piped`
    // is set by prePoint, so its absence is the signal.
    if (!pending.piped) {
      commit(ctx, pending, "_", "direct")
      ctx.out.remove(COST_PENDING_KEY)
    }

    if (err != null) throw err
    res
  }

  private def pendingFor(ctx: Context): CostPending = {
    ctx.out.get(COST_PENDING_KEY) match {
      case p: CostPending => p
      case _ =>
        val pending = new CostPending()
        ctx.out.put(COST_PENDING_KEY, pending)
        pending
    }
  }

  // Attribute the operation's spend once the call is finished.
  override def preDone(ctx: Context): Unit = finish(ctx, true)

  // A failed operation still spent the money. When the pipeline errors,
  // preDone never runs, so without this the attempts are counted and the
  // spend is not, and a budget could never see the cost of a failed call.
  // Whichever hook fires first consumes the pending entry, so it commits
  // exactly once.
  override def preUnexpected(ctx: Context): Unit = finish(ctx, false)

  private def finish(ctx: Context, done: Boolean): Unit = {
    if (!this.active) return

    val pending = ctx.out.get(COST_PENDING_KEY) match {
      case p: CostPending => p
      case _ => return
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
    if (!done && pending.attempts == 0) return

    var entity = "_"
    var opname = "_"
    if (ctx.op != null) {
      if (ctx.op.entity != null && !"".equals(ctx.op.entity)) entity = ctx.op.entity
      if (ctx.op.name != null && !"".equals(ctx.op.name)) opname = ctx.op.name
    }

    commit(ctx, pending, entity, opname)
  }

  // Commit one operation's spend: totals, budget, per-op and per-actor
  // attribution, and the record. Shared by finish and the raw-request path
  // in charge, which has no preDone to reach.
  private def commit(ctx: Context, pending: CostPending, entity: String, opname: String): Unit = {
    var amount = pending.amount
    var reported = pending.reported
    var estimated = pending.estimated
    var source = pending.source

    // A body figure prices the whole call, so it replaces the per-attempt
    // estimate rather than adding to it - and, being server-stated, the
    // whole amount counts as reported.
    val body = bodyAmount(ctx)
    if (body != null) {
      amount = body.doubleValue()
      reported = amount
      estimated = 0.0
      source = "body"
    }

    spend(amount, reported, estimated)

    var actor = "anonymous"
    val optActor = FeatureOptions.foptStr(this.options, "actor", "")
    if (!"".equals(optActor)) actor = optActor
    if (ctx.ctrl != null && ctx.ctrl.actor != null && !"".equals(ctx.ctrl.actor)) {
      actor = ctx.ctrl.actor
    }

    this.total.calls += 1
    bump(this.ops, entity + "." + opname, amount)
    bump(this.actors, actor, amount)

    this.seq += 1
    val record = new CostRecord()
    record.seq = this.seq
    record.entity = entity
    record.op = opname
    record.actor = actor
    record.amount = amount
    record.currency = this.currency
    record.source = source
    record.attempts = pending.attempts
    this.last = record

    this.options match {
      case null =>
      case o => o.get("sink") match {
        case c: java.util.function.Consumer[_] =>
          // A sink must never break the call it is reporting on.
          try c.asInstanceOf[java.util.function.Consumer[CostRecord]].accept(record)
          catch { case _: RuntimeException => }
        case _ =>
      }
    }
  }

  // Price one attempt: a reported header figure, else the rate table, else
  // the flat unit.
  private def price(ctx: Context, res: Object): (Double, String) = {
    val header = FeatureOptions.foptStr(this.options, "header", "")
    if (!"".equals(header)) {
      val v = headerNum(res, header)
      if (v != null) return (v.doubleValue() * perUnit(), "header")
    }

    val rate = rateFor(ctx)
    if (rate != null) return (rate.doubleValue(), "table")

    val unit = FeatureOptions.foptNum(this.options, "unit", 0)
    if (unit != 0) return (unit, "unit")

    (0.0, "none")
  }

  // The rate table uses the same lookup grammar as rbac's rules:
  // '<entity>.<op>', then '<op>', then '*'.
  private def rateFor(ctx: Context): java.lang.Double = {
    val rates = FeatureOptions.foptMap(this.options, "rates")
    if (rates == null) return null

    var entity = ""
    if (ctx.entity != null) entity = ctx.entity.getName()
    else if (ctx.op != null) entity = ctx.op.entity
    var opname = ""
    if (ctx.op != null) opname = ctx.op.name

    val keys = Array(entity + "." + opname, opname, "*")
    var i = 0
    while (i < keys.length) {
      rates.get(keys(i)) match {
        case n: java.lang.Number => return java.lang.Double.valueOf(n.doubleValue())
        case _ =>
      }
      i += 1
    }
    null
  }

  // A usage figure from the parsed result body, priced by perUnit. Read
  // here, not at the transport seam, because the body is consumed once.
  private def bodyAmount(ctx: Context): java.lang.Double = {
    val path = FeatureOptions.foptStr(this.options, "path", "")
    if ("".equals(path)) return null
    if (ctx.result == null) return null
    ctx.result.body match {
      case m: JMap[_, _] =>
        Struct.getpath(m, path) match {
          case n: java.lang.Number => java.lang.Double.valueOf(n.doubleValue() * perUnit())
          case _ => null
        }
      case _ => null
    }
  }

  private def spend(amount: Double, reported: Double, estimated: Double): Unit = {
    this.total.amount += amount
    this.total.reported += reported
    this.total.estimated += estimated

    this.budget.spent = this.total.amount
    if (this.budget.limit > 0) {
      this.budget.remaining = Math.max(0.0, this.budget.limit - this.total.amount)
      if (this.total.amount >= this.budget.limit) this.budget.exceeded = true
    } else {
      this.budget.remaining = 0.0
    }
  }

  private def bump(bucket: JMap[String, CostBucket], key: String, amount: Double): Unit = {
    var b = bucket.get(key)
    if (b == null) {
      b = new CostBucket()
      bucket.put(key, b)
    }
    b.calls += 1
    b.amount += amount
  }

  // HTTP header names are case-insensitive and a custom transport keeps
  // conventional casing ("X-Request-Cost"), so fresHeader scans rather than
  // indexes.
  private def headerNum(res: Object, name: String): java.lang.Double = {
    val v = FeatureOptions.fresHeader(res, name)
    if ("".equals(v)) return null
    try java.lang.Double.valueOf(java.lang.Double.parseDouble(v.trim))
    catch { case _: RuntimeException => null }
  }

  private def perUnit(): Double = FeatureOptions.foptNum(this.options, "perUnit", 0)

  private def limit(): Double = FeatureOptions.foptNum(this.options, "budget", 0)
}
