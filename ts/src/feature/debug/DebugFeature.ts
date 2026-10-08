
import type { Context, FeatureOptions } from '../../types'
import type { UnivecSDK } from '../../UnivecSDK'

import { BaseFeature } from '../base/BaseFeature'


class DebugFeature extends BaseFeature {
  version = '0.0.1'
  name = 'debug'
  active = true

  _client?: UnivecSDK
  _options: any = {}
  _entries: WeakMap<object, any> = new WeakMap()


  init(ctx: Context, options: FeatureOptions): void | Promise<any> {
    this._client = ctx.client
    this._options = options || {}
    this.active = (options as any).active
    this._entries = new WeakMap()

    const client: any = this._client
    if (null == client._debug) {
      client._debug = { entries: [] }
    }
  }


  PreRequest(this: any, ctx: any) {
    const spec = ctx.spec || {}
    const entry = {
      op: ((ctx.op && ctx.op.entity) || '_') + '.' + ((ctx.op && ctx.op.name) || '_'),
      method: spec.method,
      url: spec.url || spec.path,
      headers: this._redact(ctx, spec.headers),
      start: this._now(),
      status: undefined as any,
      ok: undefined as any,
      durationMs: undefined as any,
      error: undefined as any,
    }
    this._entries.set(ctx, entry)
  }


  PreResponse(this: any, ctx: any) {
    const entry = this._entries.get(ctx)
    if (null == entry) {
      return
    }
    const response = ctx.response
    if (null != response) {
      entry.status = response.status
      entry.url = entry.url || (ctx.spec && ctx.spec.url)
    }
  }


  PreDone(this: any, ctx: any) {
    this._finish(ctx, true)
  }


  PreUnexpected(this: any, ctx: any) {
    const entry = this._entries.get(ctx)
    if (null != entry && ctx.ctrl) {
      entry.error = ctx.ctrl.err && ctx.ctrl.err.message
    }
    this._finish(ctx, false)
  }


  _finish(this: any, ctx: any, ok: boolean) {
    let entry = this._entries.get(ctx)
    if (null == entry) {
      return
    }
    this._entries.delete(ctx)
    entry.ok = ok && (null == ctx.result || false !== ctx.result.ok)
    entry.durationMs = Math.max(0, this._now() - entry.start)
    if (null == entry.status && null != ctx.result) {
      entry.status = ctx.result.status
    }

    // The whole entry leaves through the buffer and the callback: the url
    // and the error message can carry a query credential the header mask
    // above never saw.
    entry = ctx.utility.clean(ctx, entry)

    const client: any = this._client
    const buf = client._debug.entries
    buf.push(entry)
    const max = null == this._options.max ? 100 : this._options.max
    while (buf.length > max) {
      buf.shift()
    }

    const onEntry = this._options.onEntry
    if ('function' === typeof onEntry) {
      try { onEntry(entry) } catch (_e) { }
    }
  }


  // The core clean rules apply (clean.keys, every registered value); the
  // feature's own `redact` list ADDS header names on top of them.
  _redact(this: any, ctx: any, headers: any): any {
    if (null == headers) {
      return {}
    }
    const patterns = (this._options.redact || []).map((n: any) => String(n).toLowerCase())
    const out: any = {}
    for (const k of Object.keys(headers)) {
      out[k] = patterns.indexOf(k.toLowerCase()) >= 0 ? '[redacted]' : headers[k]
    }
    return ctx.utility.clean(ctx, out)
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
  DebugFeature
}
