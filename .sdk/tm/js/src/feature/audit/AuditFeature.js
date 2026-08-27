

const { BaseFeature } = require('../base/BaseFeature')


// Audit trail. Emits a structured record for every operation — who (actor),
// what (entity + op), the outcome, and a correlation id — suitable for
// compliance logging. Records accumulate on `client._audit.records`
// (bounded by `max`) and, when a `sink` callback is supplied, are also
// pushed to it (e.g. to forward to a SIEM). The actor is taken from options
// (`actor`) or a per-call `ctrl.actor`. Timestamps use the injectable
// `now` clock so tests stay deterministic.
class AuditFeature extends BaseFeature {
  version = '0.0.1'
  name = 'audit'
  active = true

  _client
  _options = {}
  _seq = 0
  _seen = new WeakSet()


  init(ctx, options) {
    this._client = ctx.client
    this._options = options || {}
    this.active = options.active
    this._seq = 0
    this._seen = new WeakSet()

    const client = this._client
    if (null == client._audit) {
      client._audit = { records: [] }
    }
  }


  PreDone(ctx) {
    // Outcome reflects the actual result; a non-2xx reaches PreDone before
    // the pipeline throws.
    this._emit(ctx, (ctx.result && false !== ctx.result.ok && null == ctx.result.err) ? 'ok' : 'error')
  }


  PreUnexpected(ctx) {
    this._emit(ctx, 'error')
  }


  _emit(ctx, outcome) {
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

    const client = this._client
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


  _now() {
    const now = this._options.now
    if ('function' === typeof now) {
      return now()
    }
    return Date.now()
  }
}


module.exports = {
  AuditFeature
}
