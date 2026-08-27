"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.LogFeature = void 0;
const BaseFeature_1 = require("../base/BaseFeature");
const pino_1 = __importDefault(require("pino"));
const pino_pretty_1 = __importDefault(require("pino-pretty"));
class LogFeature extends BaseFeature_1.BaseFeature {
    version = '0.0.1';
    name = 'log';
    active = true;
    _client;
    _options;
    _logger;
    init(ctx, options) {
        this._client = ctx.client;
        this._options = options;
        this.active = options.active;
        if (this.active) {
            let logger = this._options.logger;
            if (null == logger) {
                let pretty = (0, pino_pretty_1.default)({
                    sync: true,
                    ignore: 'ctx',
                });
                let level = this._options.level || 'info';
                logger = (0, pino_1.default)({ name: 'log', level }, pretty);
                this._logger = logger;
            }
        }
    }
    PostConstruct(ctx) {
        this._loghook('PostConstruct', ctx);
    }
    PostConstructEntity(ctx) {
        this._loghook('PostConstructEntity', ctx);
    }
    SetData(ctx) {
        this._loghook('SetData', ctx);
    }
    GetData(ctx) {
        this._loghook('GetData', ctx);
    }
    GetMatch(ctx) {
        this._loghook('GetMatch', ctx);
    }
    PrePoint(ctx) {
        this._loghook('PrePoint', ctx);
    }
    PreSpec(ctx) {
        this._loghook('PreSpec', ctx);
    }
    PreRequest(ctx) {
        this._loghook('PreRequest', ctx);
    }
    PreResponse(ctx) {
        this._loghook('PreResponse', ctx);
    }
    PreResult(ctx) {
        this._loghook('PreResult', ctx);
    }
    _loghook(hook, ctx, level) {
        level = level || 'info';
        if (this._logger) {
            this._logger[level]({
                hook,
                op: ctx.op,
                spec: ctx.spec,
                ctx
            });
        }
    }
}
exports.LogFeature = LogFeature;
//# sourceMappingURL=LogFeature.js.map