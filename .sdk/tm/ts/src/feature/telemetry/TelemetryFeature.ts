
import type { Context, FeatureOptions } from '../../types'
import type { UnivecSDK } from '../../UnivecSDK'

import { BaseFeature } from '../base/BaseFeature'


// Distributed-tracing telemetry. Opens a span per operation (PrePoint),
// propagates trace context to the server as W3C `traceparent` plus
// `X-Trace-Id` / `X-Span-Id` headers (PreRequest), and closes the span on
// completion (PreDone) or failure (PreUnexpected). Finished spans are kept
// on `client._telemetry.spans`; an `exporter` callback, when provided, is
// invoked with each finished span. Trace/span id generation and the clock
// are injectable for deterministic tests.
class TelemetryFeature extends BaseFeature {
  version = '0.0.1'
  name = 'telemetry'
  active = true

  _client?: UnivecSDK
  _options: any = {}
  _spans: WeakMap<object, any> = new WeakMap()
  _seq = 0


  init(ctx: Context, options: FeatureOptions): void | Promise<any> {
    this._client = ctx.client
    this._options = options || {}
    this.active = (options as any).active
    this._spans = new WeakMap()
    this._seq = 0

    const client: any = this._client
    if (null == client._telemetry) {
      client._telemetry = { spans: [], active: 0 }
    }
  }


  PrePoint(this: any, ctx: any) {
    const span = {
      traceId: this._id('trace'),
      spanId: this._id('span'),
      name: ((ctx.op && ctx.op.entity) || '_') + '.' + ((ctx.op && ctx.op.name) || '_'),
      start: this._now(),
      end: undefined as any,
      durationMs: undefined as any,
      ok: undefined as any,
    }
    this._spans.set(ctx, span)
    const client: any = this._client
    client._telemetry.active++
  }


  PreRequest(this: any, ctx: any) {
    const span = this._spans.get(ctx)
    const spec = ctx.spec
    if (null == span || null == spec) {
      return
    }
    if (null == spec.headers) {
      spec.headers = {}
    }
    const h = this._options.headers || {}
    spec.headers[h.trace || 'X-Trace-Id'] = span.traceId
    spec.headers[h.span || 'X-Span-Id'] = span.spanId
    spec.headers[h.parent || 'traceparent'] =
      '00-' + span.traceId + '-' + span.spanId + '-01'
  }


  PreDone(this: any, ctx: any) {
    this._close(ctx, !!(ctx.result && false !== ctx.result.ok && null == ctx.result.err))
  }


  PreUnexpected(this: any, ctx: any) {
    this._close(ctx, false)
  }


  _close(this: any, ctx: any, ok: boolean) {
    // Close once per operation; a PreDone followed by a pipeline throw
    // (non-2xx) fires PreUnexpected too, which then finds no open span.
    const span = this._spans.get(ctx)
    if (null == span) {
      return
    }
    this._spans.delete(ctx)
    span.end = this._now()
    span.durationMs = Math.max(0, span.end - span.start)
    span.ok = ok

    const client: any = this._client
    client._telemetry.active--
    client._telemetry.spans.push(span)

    const exporter = this._options.exporter
    if ('function' === typeof exporter) {
      try { exporter(span) } catch (_e) { }
    }
  }


  _id(this: any, kind: string): string {
    const idgen = this._options.idgen
    if ('function' === typeof idgen) {
      return idgen(kind)
    }
    // Deterministic-ish sequential id; unique within a client instance.
    this._seq++
    const n = this._seq.toString(16).padStart(4, '0')
    return (kind === 'trace' ? 't' : 's') + n.padEnd(16, '0')
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
  TelemetryFeature
}
