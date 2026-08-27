
import type { Context, FeatureOptions } from '../../types'
import type { UnivecSDK } from '../../UnivecSDK'

import { BaseFeature } from '../base/BaseFeature'


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

  _client?: UnivecSDK
  _options: any = {}
  _starts: WeakMap<object, number> = new WeakMap()


  init(ctx: Context, options: FeatureOptions): void | Promise<any> {
    this._client = ctx.client
    this._options = options || {}
    this.active = (options as any).active
    this._starts = new WeakMap()

    const client: any = this._client
    if (null == client._metrics) {
      client._metrics = {
        total: { count: 0, ok: 0, err: 0, totalMs: 0, maxMs: 0 },
        ops: {},
      }
    }
  }


  PrePoint(this: any, ctx: any) {
    this._starts.set(ctx, this._now())
  }


  PreDone(this: any, ctx: any) {
    // Classify by the actual result: a 4xx/5xx that flows through still
    // reaches PreDone before the pipeline throws.
    this._record(ctx, !!(ctx.result && false !== ctx.result.ok && null == ctx.result.err))
  }


  PreUnexpected(this: any, ctx: any) {
    this._record(ctx, false)
  }


  _record(this: any, ctx: any, ok: boolean) {
    // Record once per operation. When a non-2xx result reaches PreDone the
    // pipeline then throws, firing PreUnexpected too; the missing start
    // marker makes the second call a no-op.
    if (!this._starts.has(ctx)) {
      return
    }
    const start = this._starts.get(ctx)
    const dur = null == start ? 0 : Math.max(0, this._now() - start)
    this._starts.delete(ctx)

    const client: any = this._client
    const m = client._metrics
    const key = ((ctx.op && ctx.op.entity) || '_') + '.' + ((ctx.op && ctx.op.name) || '_')

    let op = m.ops[key]
    if (null == op) {
      op = m.ops[key] = { count: 0, ok: 0, err: 0, totalMs: 0, maxMs: 0 }
    }

    this._bump(m.total, ok, dur)
    this._bump(op, ok, dur)
  }


  _bump(this: any, bucket: any, ok: boolean, dur: number) {
    bucket.count++
    bucket[ok ? 'ok' : 'err']++
    bucket.totalMs += dur
    if (dur > bucket.maxMs) {
      bucket.maxMs = dur
    }
  }


  _now(this: any): number {
    const now = this._options.now
    if ('function' === typeof now) {
      return now()
    }
    return Date.now()
  }
}


export {
  MetricsFeature
}
