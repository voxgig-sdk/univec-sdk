
import type { Context, FeatureOptions } from '../../types'
import type { UnivecSDK } from '../../UnivecSDK'

import { BaseFeature } from '../base/BaseFeature'


// Idempotency keys for mutating operations. Adds an `Idempotency-Key`
// header (name configurable) to unsafe requests so a server can
// de-duplicate retried writes. The key is set once, at PreRequest, before
// the request is built — so it is stable across transport-level retries of
// the same call. A caller-supplied header is never overwritten.
class IdempotencyFeature extends BaseFeature {
  version = '0.0.1'
  name = 'idempotency'
  active = true

  _client?: UnivecSDK
  _options: any = {}


  init(ctx: Context, options: FeatureOptions): void | Promise<any> {
    this._client = ctx.client
    this._options = options || {}
    this.active = (options as any).active
  }


  PreRequest(this: any, ctx: any) {
    const spec = ctx.spec
    if (null == spec) {
      return
    }

    if (!this._mutating(ctx)) {
      return
    }

    const header = this._options.header || 'Idempotency-Key'
    if (null == spec.headers) {
      spec.headers = {}
    }

    // Respect a key the caller already provided.
    if (null != this._existing(spec.headers, header)) {
      return
    }

    const key = this._genkey()
    spec.headers[header] = key

    const client: any = this._client
    if (null == client._idempotency) {
      client._idempotency = { issued: 0, last: undefined }
    }
    client._idempotency.issued++
    client._idempotency.last = key
  }


  _mutating(this: any, ctx: any): boolean {
    const methods = this._options.methods || ['POST', 'PUT', 'PATCH', 'DELETE']
    const method = ((ctx.spec && ctx.spec.method) || '').toUpperCase()
    if (method && methods.indexOf(method) >= 0) {
      return true
    }
    const opname = ctx.op && ctx.op.name
    const ops = this._options.ops || ['create', 'update', 'remove']
    return ops.indexOf(opname) >= 0
  }


  _existing(this: any, headers: any, header: string): any {
    const lower = header.toLowerCase()
    for (const k of Object.keys(headers)) {
      if (k.toLowerCase() === lower) {
        return headers[k]
      }
    }
    return undefined
  }


  _genkey(this: any): string {
    const keygen = this._options.keygen
    if ('function' === typeof keygen) {
      return keygen()
    }
    const h = () => (1e7 * Math.random() | 0).toString(16)
    return (h() + h() + h() + h()).padEnd(24, '0').slice(0, 24)
  }
}


export {
  IdempotencyFeature
}
