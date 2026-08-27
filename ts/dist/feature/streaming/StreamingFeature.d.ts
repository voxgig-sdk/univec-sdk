import type { Context, FeatureOptions } from '../../types';
import type { UnivecSDK } from '../../UnivecSDK';
import { BaseFeature } from '../base/BaseFeature';
declare class StreamingFeature extends BaseFeature {
    version: string;
    name: string;
    active: boolean;
    _client?: UnivecSDK;
    _options: any;
    init(ctx: Context, options: FeatureOptions): void | Promise<any>;
    PreResult(this: any, ctx: any): void;
    _iterate(this: any, result: any): any;
    _streamable(this: any, ctx: any): boolean;
    _sleep(this: any, ms: number): Promise<void>;
}
export { StreamingFeature };
