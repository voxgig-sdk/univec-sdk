
import type { Context, FeatureOptions } from '../../types'
import type { UnivecSDK } from '../../UnivecSDK'

import { BaseFeature } from '../base/BaseFeature'


// Streaming result support. For list-style operations it attaches a
// `result.stream()` async-iterator so callers can consume items
// incrementally with `for await (const item of result.stream())` instead of
// materialising the whole array. The iterator reads the result's data
// lazily, so it reflects the parsed entities. A `chunkDelay` (ms) simulates
// paced/chunked delivery for offline tests via the injectable `sleep`; a
// `chunkSize` groups items into batches when set.
class StreamingFeature extends BaseFeature {
  version = '0.0.1'
  name = 'streaming'
  active = true

  _client?: UnivecSDK
  _options: any = {}


  init(ctx: Context, options: FeatureOptions): void | Promise<any> {
    this._client = ctx.client
    this._options = options || {}
    this.active = (options as any).active
  }


  PreResult(this: any, ctx: any) {
    if (!this._streamable(ctx)) {
      return
    }
    const result = ctx.result
    if (null == result) {
      return
    }

    const self = this
    result.streaming = true

    result.stream = function () {
      return self._iterate(result)
    }

    const client: any = this._client
    if (null == client._streaming) {
      client._streaming = { opened: 0 }
    }
    client._streaming.opened++
  }


  async *_iterate(this: any, result: any): any {
    const chunkDelay = this._options.chunkDelay || 0
    const chunkSize = this._options.chunkSize || 0

    // Read lazily so downstream result processing is reflected.
    const items = Array.isArray(result.resdata) ? result.resdata : []

    if (0 < chunkSize) {
      for (let i = 0; i < items.length; i += chunkSize) {
        if (0 < chunkDelay) { await this._sleep(chunkDelay) }
        yield items.slice(i, i + chunkSize)
      }
      return
    }

    for (const item of items) {
      if (0 < chunkDelay) { await this._sleep(chunkDelay) }
      yield item
    }
  }


  _streamable(this: any, ctx: any): boolean {
    const ops = this._options.ops || ['list']
    return ops.indexOf(ctx.op && ctx.op.name) >= 0
  }


  _sleep(this: any, ms: number): Promise<void> {
    if (null == ms || 0 >= ms) {
      return Promise.resolve()
    }
    const sleep = this._options.sleep
    if ('function' === typeof sleep) {
      return Promise.resolve(sleep(ms))
    }
    return new Promise((r) => setTimeout(r, ms))
  }
}


export {
  StreamingFeature
}
