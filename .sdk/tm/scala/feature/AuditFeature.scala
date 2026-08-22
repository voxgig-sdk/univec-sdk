package SCALAPACKAGE.feature

import java.util.{ArrayList, LinkedHashMap, List => JList, Map => JMap}
import SCALAPACKAGE.core.{Context, SdkClient}

// Audit trail. Emits a structured record for every operation — who (actor),
// what (entity + op), the outcome, and a correlation id — suitable for
// compliance logging. Records accumulate on the feature (bounded by `max`,
// default 1000) and, when a `sink` callback is supplied, are also pushed to
// it (e.g. to forward to a SIEM). The actor is the per-call ctrl actor,
// falling back to the options `actor`, then "anonymous". Each operation is
// audited exactly once (the per-context marker in ctx.out prevents a
// PreDone + PreUnexpected double-log). Timestamps use the injectable `now`
// clock so tests stay deterministic.
class AuditFeature extends BaseFeature("audit", "0.0.1", true) {

  private var client: SdkClient = null
  private var options: JMap[String, Object] = null
  private var seq: Int = 0

  // Activity tracking (mirrors the ts client._audit record).
  var records: JList[JMap[String, Object]] = new ArrayList[JMap[String, Object]]()

  private val AUDIT_SEEN_KEY = "audit_seen"

  override def init(ctx: Context, options: JMap[String, Object]): Unit = {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)
    this.seq = 0
  }

  override def preDone(ctx: Context): Unit = {
    // Outcome reflects the actual result; a non-2xx reaches PreDone before
    // the pipeline errors.
    var outcome = "error"
    if (ctx.result != null && ctx.result.ok && ctx.result.err == null) {
      outcome = "ok"
    }
    emit(ctx, outcome)
  }

  override def preUnexpected(ctx: Context): Unit = {
    emit(ctx, "error")
  }

  private def emit(ctx: Context, outcome: String): Unit = {
    if (!this.active) {
      return
    }

    // One record per operation (PreDone + a following PreUnexpected on a
    // failure must not double-log).
    if (java.lang.Boolean.TRUE == ctx.out.get(AUDIT_SEEN_KEY)) {
      return
    }
    ctx.out.put(AUDIT_SEEN_KEY, java.lang.Boolean.TRUE)

    this.seq += 1

    var actor = "anonymous"
    val optActor = FeatureOptions.foptStr(this.options, "actor", "")
    if (!"".equals(optActor)) {
      actor = optActor
    }
    if (ctx.ctrl != null && ctx.ctrl.actor != null && !"".equals(ctx.ctrl.actor)) {
      actor = ctx.ctrl.actor
    }

    var entity = "_"
    var opname = "_"
    if (ctx.op != null) {
      entity = ctx.op.entity
      opname = ctx.op.name
    }

    val record = new LinkedHashMap[String, Object]()
    record.put("seq", java.lang.Integer.valueOf(this.seq))
    record.put("ts", java.lang.Long.valueOf(FeatureOptions.foptNow(this.options).getAsLong()))
    record.put("actor", actor)
    record.put("entity", entity)
    record.put("op", opname)
    record.put("outcome", outcome)
    record.put("correlationId", ctx.id)
    if (ctx.result != null) {
      record.put("status", java.lang.Integer.valueOf(ctx.result.status))
    }

    this.records.add(record)
    val max = FeatureOptions.foptInt(this.options, "max", 1000)
    while (this.records.size() > max) {
      this.records.remove(0)
    }

    this.options.get("sink") match {
      case c: java.util.function.Consumer[_] =>
        c.asInstanceOf[java.util.function.Consumer[JMap[String, Object]]].accept(record)
      case _ =>
    }
  }
}
