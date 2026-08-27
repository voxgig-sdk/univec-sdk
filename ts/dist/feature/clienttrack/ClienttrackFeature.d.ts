import type { Context, FeatureOptions } from '../../types';
import type { UnivecSDK } from '../../UnivecSDK';
import { BaseFeature } from '../base/BaseFeature';
declare class ClienttrackFeature extends BaseFeature {
    version: string;
    name: string;
    active: boolean;
    _client?: UnivecSDK;
    _options: any;
    _session: string;
    _requests: number;
    init(ctx: Context, options: FeatureOptions): void | Promise<any>;
    PostConstruct(this: any, _ctx: any): void;
    PreRequest(this: any, ctx: any): void;
    _set(this: any, headers: any, name: string, value: string): void;
    _name(this: any): string;
    _genid(this: any, kind: string): string;
}
export { ClienttrackFeature };
