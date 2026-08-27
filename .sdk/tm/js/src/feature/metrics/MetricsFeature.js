

const { BaseFeature } = require('../base/BaseFeature')


// Statistics capture. Records per-operation counters and latency for every
// call: totals plus a breakdown keyed by `<entity>.<op>`. Timing starts at
// endpoint resolution (PrePoint) and stops when the call returns (PreDone)
// or throws (PreUnexpected). Aggregates live on `client._metrics` and can be
// read via `client.metrics()` in the generated SDK. The clock is injectable
// (`now`) for deterministic tests.
class MetricsFeature extends BaseFeature {
  version = '0.0.1'
  name = 'metrics'
  active = true

  _client
  _options = {}
  _starts = new WeakMap()


  init(ctx, options) {
    this._client = ctx.client
    this._options = options || {}
    this.active = options.active
    this._starts = new WeakMap()

    const client = this._client
    if (null == client._metrics) {
      client._metrics = {
        total: { count: 0, ok: 0, err: 0, totalMs: 0, maxMs: 0 },
        ops: {},
      }
    }
  }


  PrePoint(ctx) {
    this._starts.set(ctx, this._now())
  }


  PreDone(ctx) {
    // Classify by the actual result: a 4xx/5xx that flows through still
    // reaches PreDone before the pipeline throws.
    this._record(ctx, !!(ctx.result && false !== ctx.result.ok && null == ctx.result.err))
  }


  PreUnexpected(ctx) {
    this._record(ctx, false)
  }


  _record(ctx, ok) {
    // Record once per operation. When a non-2xx result reaches PreDone the
    // pipeline then throws, firing PreUnexpected too; the missing start
    // marker makes the second call a no-op.
    if (!this._starts.has(ctx)) {
      return
    }
    const start = this._starts.get(ctx)
    const dur = null == start ? 0 : Math.max(0, this._now() - start)
    this._starts.delete(ctx)

    const client = this._client
    const m = client._metrics
    const key = ((ctx.op && ctx.op.entity) || '_') + '.' + ((ctx.op && ctx.op.name) || '_')

    let op = m.ops[key]
    if (null == op) {
      op = m.ops[key] = { count: 0, ok: 0, err: 0, totalMs: 0, maxMs: 0 }
    }

    this._bump(m.total, ok, dur)
    this._bump(op, ok, dur)
  }


  _bump(bucket, ok, dur) {
    bucket.count++
    bucket[ok ? 'ok' : 'err']++
    bucket.totalMs += dur
    if (dur > bucket.maxMs) {
      bucket.maxMs = dur
    }
  }


  _now() {
    const now = this._options.now
    if ('function' === typeof now) {
      return now()
    }
    return Date.now()
  }
}


module.exports = {
  MetricsFeature
}
