import type { Context, FeatureOptions } from '../../types';
import type { UnivecSDK } from '../../UnivecSDK';
import { BaseFeature } from '../base/BaseFeature';
declare class CacheFeature extends BaseFeature {
    version: string;
    name: string;
    active: boolean;
    _client?: UnivecSDK;
    _options: any;
    _store: Map<string, any>;
    init(ctx: Context, options: FeatureOptions): void | Promise<any>;
    _through(this: any, ctx: any, url: string, fetchdef: any, inner: any): Promise<any>;
    _cacheable(this: any, res: any): boolean;
    _snapshot(this: any, res: any): Promise<any>;
    _replay(this: any, snapshot: any): any;
    _evict(this: any): void;
    _now(this: any): number;
    _track(this: any, kind: string): void;
}
export { CacheFeature };
