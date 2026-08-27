import type { Context, FeatureOptions } from '../../types';
import type { UnivecSDK } from '../../UnivecSDK';
import { BaseFeature } from '../base/BaseFeature';
declare class LogFeature extends BaseFeature {
    version: string;
    name: string;
    active: boolean;
    _client?: UnivecSDK;
    _options?: any;
    _logger?: any;
    init(ctx: Context, options: FeatureOptions): void | Promise<any>;
    PostConstruct(this: any, ctx: any): void;
    PostConstructEntity(this: any, ctx: any): void;
    SetData(this: any, ctx: any): void;
    GetData(this: any, ctx: any): void;
    GetMatch(this: any, ctx: any): void;
    PrePoint(this: any, ctx: any): void;
    PreSpec(this: any, ctx: any): void;
    PreRequest(this: any, ctx: any): void;
    PreResponse(this: any, ctx: any): void;
    PreResult(this: any, ctx: any): void;
    _loghook(this: any, hook: any, ctx: any, level: any): void;
}
export { LogFeature };
