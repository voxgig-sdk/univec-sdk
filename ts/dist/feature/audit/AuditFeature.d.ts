import type { Context, FeatureOptions } from '../../types';
import type { UnivecSDK } from '../../UnivecSDK';
import { BaseFeature } from '../base/BaseFeature';
declare class AuditFeature extends BaseFeature {
    version: string;
    name: string;
    active: boolean;
    _client?: UnivecSDK;
    _options: any;
    _seq: number;
    _seen: WeakSet<object>;
    init(ctx: Context, options: FeatureOptions): void | Promise<any>;
    PreDone(this: any, ctx: any): void;
    PreUnexpected(this: any, ctx: any): void;
    _emit(this: any, ctx: any, outcome: string): void;
    _now(this: any): number;
}
export { AuditFeature };
