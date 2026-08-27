// Statistics capture. Records per-operation counters and latency for every
// call: totals plus a breakdown keyed by `<entity>.<op>`. Timing starts at
// endpoint resolution (prePoint) and stops when the call returns (preDone)
// or fails (preUnexpected); each operation is recorded exactly once (the
// per-context start marker in ctx.out is consumed on record). The clock is
// injectable (`now`) for deterministic tests.

import Foundation

public final class MetricsBucket {
  public var count = 0
  public var ok = 0
  public var err = 0
  public var totalMs: Int64 = 0
  public var maxMs: Int64 = 0
  public init() {}
}

public final class MetricsFeature: BaseFeature {
  private var client: UnivecSDK?
  private var options: VMap?

  // Aggregates (mirrors the ts client._metrics record).
  public var total = MetricsBucket()
  public var ops: [String: MetricsBucket] = [:]

  private static let startKey = "metrics_start"

  public override init() {
    super.init()
    version = "0.0.1"
    name = "metrics"
    active = true
  }

  public override func initFeature(_ ctx: Context, _ options: VMap) {
    client = ctx.client
    self.options = options
    active = foptBool(options, "active", false)

    total = MetricsBucket()
    ops = [:]
  }

  public override func prePoint(_ ctx: Context) {
    if !active {
      return
    }
    ctx.out[MetricsFeature.startKey] = foptNow(options)()
  }

  public override func preDone(_ ctx: Context) {
    // Classify by the actual result: a 4xx/5xx that flows through still
    // reaches preDone before the pipeline errors.
    record(ctx, ctx.result != nil && ctx.result!.ok && ctx.result!.err == nil)
  }

  public override func preUnexpected(_ ctx: Context) {
    record(ctx, false)
  }

  private func record(_ ctx: Context, _ ok: Bool) {
    // Record once per operation: the missing start marker makes a second
    // call (preDone followed by preUnexpected on failure) a no-op.
    guard let start = ctx.out[MetricsFeature.startKey] as? Int64 else {
      return
    }
    ctx.out.removeValue(forKey: MetricsFeature.startKey)

    var dur = foptNow(options)() - start
    if dur < 0 {
      dur = 0
    }

    let entity = ctx.op?.entity ?? "_"
    let opname = ctx.op?.name ?? "_"
    let key = entity + "." + opname

    let op: MetricsBucket
    if let existing = ops[key] {
      op = existing
    } else {
      op = MetricsBucket()
      ops[key] = op
    }

    bump(total, ok, dur)
    bump(op, ok, dur)
  }

  private func bump(_ bucket: MetricsBucket, _ ok: Bool, _ dur: Int64) {
    bucket.count += 1
    if ok {
      bucket.ok += 1
    } else {
      bucket.err += 1
    }
    bucket.totalMs += dur
    if dur > bucket.maxMs {
      bucket.maxMs = dur
    }
  }
}
