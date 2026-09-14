import type { Context, FeatureOptions } from '../../types';
import { BaseFeature } from '../base/BaseFeature';
import { Sekreto } from './sekreto';
declare class SecretsFeature extends BaseFeature {
    version: string;
    name: string;
    _client: any;
    _sekreto?: Sekreto;
    _secretname: string;
    _resolving?: Promise<void>;
    _cache: boolean;
    _exchange: any;
    _refresh?: string;
    _buying?: Promise<string>;
    init(ctx: Context, fopts: FeatureOptions): void;
    sekreto(): any;
    PreSpec(_ctx: Context): Promise<void>;
    resolve(): Promise<void>;
    private _resolveonce;
    private _buy;
    private _buyonce;
    _withRefresh(this: any, ctx: any, url: string, fetchdef: any, inner: any): Promise<any>;
    _spent(this: any, res: any): boolean;
    _reauth(this: any, fetchdef: any, token: string): void;
}
export { SecretsFeature };
