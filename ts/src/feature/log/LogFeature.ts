
import type { Context, FeatureOptions } from '../../types'
import type { UnivecSDK } from '../../UnivecSDK'

import { BaseFeature } from '../base/BaseFeature'


import Pino from 'pino'
import PinoPretty from 'pino-pretty'



class LogFeature extends BaseFeature {
  version = '0.0.1'
  name = 'log'
  active = true

  _client?: UnivecSDK
  _options?: any
  _logger?: any


  init(ctx: Context, options: FeatureOptions): void | Promise<any> {
    this._client = ctx.client
    this._options = options as any
    this.active = options.active

    if (this.active) {
      let logger = this._options.logger

      if (null == logger) {
        let pretty = PinoPretty({
          sync: true,
          ignore: 'ctx',
        })

        let level = this._options.level || 'info'

        logger = Pino({ name: 'log', level }, pretty)

        this._logger = logger
      }
    }
  }


  PostConstruct(this: any, ctx: any) {
    this._loghook('PostConstruct', ctx)
  }

  PostConstructEntity(this: any, ctx: any) {
    this._loghook('PostConstructEntity', ctx)
  }

  SetData(this: any, ctx: any) {
    this._loghook('SetData', ctx)
  }

  GetData(this: any, ctx: any) {
    this._loghook('GetData', ctx)
  }

  GetMatch(this: any, ctx: any) {
    this._loghook('GetMatch', ctx)
  }


  PrePoint(this: any, ctx: any) {
    this._loghook('PrePoint', ctx)
  }

  PreSpec(this: any, ctx: any) {
    this._loghook('PreSpec', ctx)
  }

  PreRequest(this: any, ctx: any) {
    this._loghook('PreRequest', ctx)
  }

  PreResponse(this: any, ctx: any) {
    this._loghook('PreResponse', ctx)
  }

  PreResult(this: any, ctx: any) {
    this._loghook('PreResult', ctx)
  }

  _loghook(this: any, hook: any, ctx: any, level: any) {
    level = level || 'info'
    if (this._logger) {
      this._logger[level]({
        hook,
        op: ctx.op,
        spec: ctx.spec,
        ctx
      })
    }
  }
}


export {
  LogFeature
}
