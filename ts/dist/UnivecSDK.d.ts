import { ConvertEntity } from './entity/ConvertEntity';
import { EmbedEntity } from './entity/EmbedEntity';
import { EphemeralKeyEntity } from './entity/EphemeralKeyEntity';
import { ModelEntity } from './entity/ModelEntity';
export type * from './UnivecTypes';
import { inspect } from 'node:util';
import type { Context, Feature } from './types';
import { config } from './Config';
import { UnivecEntityBase } from './UnivecEntityBase';
import { Utility } from './utility/Utility';
import { BaseFeature } from './feature/base/BaseFeature';
import * as sekreto from './feature/secrets/sekreto';
declare const stdutil: Utility;
declare class UnivecSDK {
    _mode: string;
    _options: any;
    _utility: Utility;
    _features: Feature[];
    _rootctx: Context;
    _secrets?: any;
    constructor(options?: any);
    options(): any;
    utility(): any;
    secrets(): any;
    prepare(fetchargs?: any): Promise<any>;
    direct(fetchargs?: any): Promise<Error | {
        ok: boolean;
        status: number;
        headers: any;
        data: any;
        err?: undefined;
    } | {
        ok: boolean;
        err: any;
        status?: undefined;
        headers?: undefined;
        data?: undefined;
    }>;
    _rawRequest(fetchargs?: any): Promise<Error | {
        ok: boolean;
        status: number;
        headers: any;
        data: any;
        err?: undefined;
    } | {
        ok: boolean;
        err: any;
        status?: undefined;
        headers?: undefined;
        data?: undefined;
    }>;
    graphql(query: string, variables?: any, ctrl?: any): Promise<any>;
    Convert(entopts?: Record<string, any>): ConvertEntity;
    Embed(entopts?: Record<string, any>): EmbedEntity;
    EphemeralKey(entopts?: Record<string, any>): EphemeralKeyEntity;
    Model(entopts?: Record<string, any>): ModelEntity;
    static test(testoptsarg?: any, sdkoptsarg?: any): UnivecSDK;
    tester(testopts?: any, sdkopts?: any): UnivecSDK;
    toJSON(): {
        name: string;
    };
    toString(): string;
    [inspect.custom](): string;
}
declare const SDK: typeof UnivecSDK;
export { stdutil, config, sekreto, BaseFeature, UnivecEntityBase, UnivecSDK, SDK, };
