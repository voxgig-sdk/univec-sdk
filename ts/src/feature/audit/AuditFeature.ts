
import type { Context, FeatureOptions } from '../../types'
import type { UnivecSDK } from '../../UnivecSDK'

import { BaseFeature } from '../base/BaseFeature'


class AuditFeature extends BaseFeature {
  version = '0.0.1'
  name = 'audit'
  active = true

  _client?: UnivecSDK
  _options: any = {}
  _seq = 0
  _seen: WeakSet<object> = new WeakSet()


  init(ctx: Context, options: FeatureOptions): void | Promise<any> {
    this._client = ctx.client
    this._options = options || {}
    this.active = (options as any).active
    this._seq = 0
    this._seen = new WeakSet()

    const client: any = this._client
    if (null == client._audit) {
      client._audit = { records: [] }
    }
  }


  PreDone(this: any, ctx: any) {
    // Outcome reflects the actual result; a non-2xx reaches PreDone before
    // the pipeline throws.
    this._emit(ctx, (ctx.result && false !== ctx.result.ok && null == ctx.result.err) ? 'ok' : 'error')
  }


  PreUnexpected(this: any, ctx: any) {
    this._emit(ctx, 'error')
  }


  _emit(this: any, ctx: any, outcome: string) {
    // One record per operation (PreDone + a following PreUnexpected on a
    // non-2xx must not double-log).
    if (this._seen.has(ctx)) {
      return
    }
    this._seen.add(ctx)
    this._seq++
    const record = {
      seq: this._seq,
      ts: this._now(),
      actor: (ctx.ctrl && ctx.ctrl.actor) || this._options.actor || 'anonymous',
      entity: (ctx.op && ctx.op.entity) || '_',
      op: (ctx.op && ctx.op.name) || '_',
      outcome,
      status: ctx.result && ctx.result.status,
      correlationId: ctx.id,
    }

    const client: any = this._client
    const recs = client._audit.records
    recs.push(record)
    const max = null == this._options.max ? 1000 : this._options.max
    while (recs.length > max) {
      recs.shift()
    }

    const sink = this._options.sink
    if ('function' === typeof sink) {
      try { sink(record) } catch (_e) { }
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
  AuditFeature
}
