import type { Context, FeatureOptions } from '../../types';
import type { UnivecSDK } from '../../UnivecSDK';
import { BaseFeature } from '../base/BaseFeature';
declare class CostFeature extends BaseFeature {
    version: string;
    name: string;
    active: boolean;
    _client?: UnivecSDK;
    _options: any;
    _pending: WeakMap<object, any>;
    _seq: number;
    init(ctx: Context, options: FeatureOptions): void | Promise<any>;
    PrePoint(this: any, ctx: any): any;
    _charge(this: any, ctx: any, url: string, fetchdef: any, inner: any): Promise<any>;
    _newPending(this: any): any;
    PreDone(this: any, ctx: any): void;
    PreUnexpected(this: any, ctx: any): void;
    _finish(this: any, ctx: any, done: boolean): void;
    _commit(this: any, ctx: any, pending: any, entity: string, opname: string): void;
    _price(this: any, ctx: any, res: any): any;
    _rate(this: any, ctx: any): number | null;
    _body(this: any, ctx: any): number | null;
    _spend(this: any, cost: any, amount: number, reported: number, estimated: number): void;
    _bump(this: any, bucket: any, key: string, amount: number): void;
    _header(this: any, res: any, name: string): number | null;
    _perUnit(this: any): number;
    _limit(this: any): number;
}
export { CostFeature };
