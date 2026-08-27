package KOTLINPACKAGE.feature

import java.util.function.Consumer

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.SdkClient

// Audit trail. Emits a structured record for every operation — who (actor),
// what (entity + op), the outcome, and a correlation id. Records accumulate
// (bounded by `max`, default 1000) and, when a `sink` callback is supplied,
// are also pushed to it. Timestamps use the injectable `now` clock.
@Suppress("UNCHECKED_CAST")
class AuditFeature : BaseFeature("audit", "0.0.1", true) {

  private var client: SdkClient? = null
  private var options: MutableMap<String, Any?>? = null
  private var seq = 0

  // Activity tracking (mirrors the ts client._audit record).
  var records: MutableList<MutableMap<String, Any?>> = mutableListOf()

  override fun init(ctx: Context, options: MutableMap<String, Any?>) {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)
    this.seq = 0
  }

  override fun preDone(ctx: Context) {
    var outcome = "error"
    val result = ctx.result
    if (result != null && result.ok && result.err == null) {
      outcome = "ok"
    }
    emit(ctx, outcome)
  }

  override fun preUnexpected(ctx: Context) {
    emit(ctx, "error")
  }

  private fun emit(ctx: Context, outcome: String) {
    if (!this.active) {
      return
    }

    // One record per operation (PreDone + a following PreUnexpected on a
    // failure must not double-log).
    if (ctx.out[AUDIT_SEEN_KEY] == true) {
      return
    }
    ctx.out[AUDIT_SEEN_KEY] = true

    this.seq++

    var actor = "anonymous"
    val optActor = FeatureOptions.foptStr(this.options, "actor", "")
    if ("" != optActor) {
      actor = optActor
    }
    if ("" != ctx.ctrl.actor) {
      actor = ctx.ctrl.actor
    }

    val entity = ctx.op.entity
    val opname = ctx.op.name

    val record = linkedMapOf<String, Any?>()
    record["seq"] = this.seq
    record["ts"] = FeatureOptions.foptNow(this.options).getAsLong()
    record["actor"] = actor
    record["entity"] = entity
    record["op"] = opname
    record["outcome"] = outcome
    record["correlationId"] = ctx.id
    val result = ctx.result
    if (result != null) {
      record["status"] = result.status
    }

    this.records.add(record)
    val max = FeatureOptions.foptInt(this.options, "max", 1000)
    while (this.records.size > max) {
      this.records.removeAt(0)
    }

    val sink = this.options?.get("sink")
    if (sink is Consumer<*>) {
      (sink as Consumer<MutableMap<String, Any?>>).accept(record)
    }
  }

  companion object {
    private const val AUDIT_SEEN_KEY = "audit_seen"
  }
}
