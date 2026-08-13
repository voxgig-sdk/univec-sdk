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
declare const stdutil: Utility;
declare class UnivecSDK {
    _mode: string;
    _options: any;
    _utility: Utility;
    _features: Feature[];
    _rootctx: Context;
    constructor(options?: any);
    options(): any;
    utility(): any;
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
export { stdutil, config, BaseFeature, UnivecEntityBase, UnivecSDK, SDK, };
