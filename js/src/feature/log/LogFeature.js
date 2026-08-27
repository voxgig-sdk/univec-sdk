

const { BaseFeature } = require('../base/BaseFeature')


const Pino = require('pino')
const PinoPretty = require('pino-pretty')



class LogFeature extends BaseFeature {
  version = '0.0.1'
  name = 'log'
  active = true

  _client
  _options
  _logger


  init(ctx, options) {
    this._client = ctx.client
    this._options = options
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


  PostConstruct(ctx) {
    this._loghook('PostConstruct', ctx)
  }

  PostConstructEntity(ctx) {
    this._loghook('PostConstructEntity', ctx)
  }

  SetData(ctx) {
    this._loghook('SetData', ctx)
  }

  GetData(ctx) {
    this._loghook('GetData', ctx)
  }

  GetMatch(ctx) {
    this._loghook('GetMatch', ctx)
  }


  PrePoint(ctx) {
    this._loghook('PrePoint', ctx)
  }

  PreSpec(ctx) {
    this._loghook('PreSpec', ctx)
  }

  PreRequest(ctx) {
    this._loghook('PreRequest', ctx)
  }

  PreResponse(ctx) {
    this._loghook('PreResponse', ctx)
  }

  PreResult(ctx) {
    this._loghook('PreResult', ctx)
  }

  _loghook(hook, ctx, level) {
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


module.exports = {
  LogFeature
}
