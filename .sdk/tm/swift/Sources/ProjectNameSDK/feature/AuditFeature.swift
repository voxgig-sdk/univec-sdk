// Audit trail. Emits a structured record for every operation - who (actor),
// what (entity + op), the outcome, and a correlation id - suitable for
// compliance logging. Records accumulate on the feature (bounded by `max`,
// default 1000) and, when a `sink` callback is supplied, are also pushed to
// it (e.g. to forward to a SIEM). The actor is the per-call ctrl actor,
// falling back to the options `actor`, then "anonymous". Each operation is
// audited exactly once (the per-context marker in ctx.out prevents a
// preDone + preUnexpected double-log). Timestamps use the injectable `now`
// clock so tests stay deterministic.

import Foundation

public final class AuditFeature: BaseFeature {
  private var client: UnivecSDK?
  private var options: VMap?
  private var seq = 0

  // Activity tracking (mirrors the ts client._audit record).
  public var records: [VMap] = []

  private static let seenKey = "audit_seen"

  public override init() {
    super.init()
    version = "0.0.1"
    name = "audit"
    active = true
  }

  public override func initFeature(_ ctx: Context, _ options: VMap) {
    client = ctx.client
    self.options = options
    active = foptBool(options, "active", false)
    seq = 0
  }

  public override func preDone(_ ctx: Context) {
    // Outcome reflects the actual result; a non-2xx reaches preDone
    // before the pipeline errors.
    var outcome = "error"
    if ctx.result != nil && ctx.result!.ok && ctx.result!.err == nil {
      outcome = "ok"
    }
    emit(ctx, outcome)
  }

  public override func preUnexpected(_ ctx: Context) {
    emit(ctx, "error")
  }

  private func emit(_ ctx: Context, _ outcome: String) {
    if !active {
      return
    }

    // One record per operation (preDone + a following preUnexpected on a
    // failure must not double-log).
    if let seen = ctx.out[AuditFeature.seenKey] as? Bool, seen {
      return
    }
    ctx.out[AuditFeature.seenKey] = true

    seq += 1

    var actor = "anonymous"
    let optActor = foptStr(options, "actor", "")
    if optActor != "" {
      actor = optActor
    }
    if ctx.ctrl.actor != "" {
      actor = ctx.ctrl.actor
    }

    let entity = ctx.op?.entity ?? "_"
    let opname = ctx.op?.name ?? "_"

    let record = VMap()
    record.entries["seq"] = .int(Int64(seq))
    record.entries["ts"] = .int(foptNow(options)())
    record.entries["actor"] = .string(actor)
    record.entries["entity"] = .string(entity)
    record.entries["op"] = .string(opname)
    record.entries["outcome"] = .string(outcome)
    record.entries["correlationId"] = .string(ctx.id)
    if let result = ctx.result {
      record.entries["status"] = .int(Int64(result.status))
    }

    records.append(record)
    let max = foptInt(options, "max", 1000)
    while records.count > max {
      records.removeFirst()
    }

    if let sink = gp(options, "sink").asNative as? (VMap) -> Void {
      sink(record)
    }
  }
}
