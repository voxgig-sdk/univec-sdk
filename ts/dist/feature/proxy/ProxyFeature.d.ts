import type { Context, FeatureOptions } from '../../types';
import type { UnivecSDK } from '../../UnivecSDK';
import { BaseFeature } from '../base/BaseFeature';
declare class ProxyFeature extends BaseFeature {
    version: string;
    name: string;
    active: boolean;
    _client?: UnivecSDK;
    _options: any;
    _url?: string;
    _noProxy: string[];
    init(ctx: Context, options: FeatureOptions): void | Promise<any>;
    _route(this: any, url: string, fetchdef: any): any;
    _bypass(this: any, url: string): boolean;
    _track(this: any, url: string): void;
}
export { ProxyFeature };
