import type { Context, FeatureOptions } from '../../types';
import type { UnivecSDK } from '../../UnivecSDK';
import { BaseFeature } from '../base/BaseFeature';
declare class NetsimFeature extends BaseFeature {
    version: string;
    name: string;
    active: boolean;
    _client?: UnivecSDK;
    _options: any;
    _calls: number;
    _seed: number;
    init(ctx: Context, options: FeatureOptions): void | Promise<any>;
    _simulate(this: any, ctx: any, url: string, fetchdef: any, inner: any): Promise<any>;
    _pickLatency(this: any): number;
    _sleep(this: any, ms: number): Promise<void>;
    _rand(this: any): number;
    _track(this: any, ctx: any, applied: any): void;
    _respond(this: any, ctx: any, status: number, data?: any, extra?: any): any;
}
export { NetsimFeature };
