import type { Context, FeatureOptions } from '../../types';
import type { UnivecSDK } from '../../UnivecSDK';
import { BaseFeature } from '../base/BaseFeature';
declare class MetricsFeature extends BaseFeature {
    version: string;
    name: string;
    active: boolean;
    _client?: UnivecSDK;
    _options: any;
    _starts: WeakMap<object, number>;
    init(ctx: Context, options: FeatureOptions): void | Promise<any>;
    PrePoint(this: any, ctx: any): void;
    PreDone(this: any, ctx: any): void;
    PreUnexpected(this: any, ctx: any): void;
    _record(this: any, ctx: any, ok: boolean): void;
    _bump(this: any, bucket: any, ok: boolean, dur: number): void;
    _now(this: any): number;
}
export { MetricsFeature };
