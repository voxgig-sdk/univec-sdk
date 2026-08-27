import type { Context, FeatureOptions } from '../../types';
import type { UnivecSDK } from '../../UnivecSDK';
import { BaseFeature } from '../base/BaseFeature';
declare class DebugFeature extends BaseFeature {
    version: string;
    name: string;
    active: boolean;
    _client?: UnivecSDK;
    _options: any;
    _entries: WeakMap<object, any>;
    init(ctx: Context, options: FeatureOptions): void | Promise<any>;
    PreRequest(this: any, ctx: any): void;
    PreResponse(this: any, ctx: any): void;
    PreDone(this: any, ctx: any): void;
    PreUnexpected(this: any, ctx: any): void;
    _finish(this: any, ctx: any, ok: boolean): void;
    _redact(this: any, headers: any): any;
    _now(this: any): number;
}
export { DebugFeature };
