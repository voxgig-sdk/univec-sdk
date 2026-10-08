
import type { Context, FeatureOptions } from '../../types'
import type { UnivecSDK } from '../../UnivecSDK'

import { BaseFeature } from '../base/BaseFeature'


class ProxyFeature extends BaseFeature {
  version = '0.0.1'
  name = 'proxy'
  active = true

  _client?: UnivecSDK
  _options: any = {}
  _url?: string
  _noProxy: string[] = []
  _ctx?: Context


  init(ctx: Context, options: FeatureOptions): void | Promise<any> {
    this._client = ctx.client
    this._options = options || {}
    this.active = (options as any).active

    if (!this.active) {
      return
    }

    this._url = this._options.url
    let noProxy = this._options.noProxy

    if (true === this._options.fromEnv && 'undefined' !== typeof process && process.env) {
      this._url = this._url || process.env.HTTPS_PROXY || process.env.https_proxy ||
        process.env.HTTP_PROXY || process.env.http_proxy
      noProxy = noProxy || process.env.NO_PROXY || process.env.no_proxy
    }

    this._noProxy = ('string' === typeof noProxy ? noProxy.split(/\s*,\s*/) : (noProxy || []))
      .filter((s: string) => null != s && '' !== s)

    // A proxy URL may carry credentials as userinfo, from the option or the
    // environment, and neither is under a sensitive key name.
    this._ctx = ctx
    if ('string' === typeof this._url) {
      try {
        const parsed = new URL(this._url)
        for (const part of [parsed.username, parsed.password]) {
          if ('' !== part) {
            ctx.utility.cleanAdd(ctx, part)
            try { ctx.utility.cleanAdd(ctx, decodeURIComponent(part)) } catch (_e) { }
          }
        }
      }
      catch (_e) { }
    }

    const self = this
    const utility = ctx.utility
    const inner = utility.fetcher

    utility.fetcher = async function (ctx2: any, url: string, fetchdef: any) {
      fetchdef = self._route(url, fetchdef)
      return inner(ctx2, url, fetchdef)
    }
  }


  _route(this: any, url: string, fetchdef: any): any {
    if (null == this._url || this._bypass(url)) {
      return fetchdef
    }

    const out = { ...fetchdef, proxy: this._url }

    const agent = this._options.agent
    if ('function' === typeof agent) {
      // Factory returns a transport-specific agent/dispatcher.
      const made = agent(this._url, url)
      out.dispatcher = made
      out.agent = made
    }

    this._track(url)
    return out
  }


  _bypass(this: any, url: string): boolean {
    if (0 === this._noProxy.length) {
      return false
    }
    let host = url
    const m = /^[a-z]+:\/\/([^/:]+)/i.exec(url)
    if (m) {
      host = m[1]
    }
    for (const np of this._noProxy) {
      if ('*' === np) {
        return true
      }
      if (host === np || host.endsWith('.' + np.replace(/^\./, ''))) {
        return true
      }
    }
    return false
  }


  _track(this: any, url: string) {
    const client: any = this._client
    if (null == client._proxy) {
      const ctx = this._ctx
      client._proxy = { routed: 0, url: null == ctx ? this._url : ctx.utility.clean(ctx, this._url) }
    }
    client._proxy.routed++
  }
}


export {
  ProxyFeature
}
