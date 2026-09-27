import { Definition } from './Catalog';
import { PointSpec } from './Host';
export declare const SDK_HOOKS: string[];
export declare const STATION_HOOKS: string[];
export declare const REQUEST_POINT = "request";
export type BridgeOptions = {
    hooks?: string[];
    replace?: string[];
    /** The SDK's REAL ctx. A feature's `init` may read `ctx.client`,
     * `ctx.utility.log` or anything else the SDK hands it, and a
     * synthetic object with one property would either give it the wrong
     * client or fail on a missing utility. The bridge layers its
     * `fetcher` trap ON TOP of this rather than replacing it. */
    ctx?: any;
};
export declare function featurepoints(fetcher: (...args: any[]) => any, options?: BridgeOptions): {
    [point: string]: PointSpec;
};
export type FeatureClass = {
    new (...args: any[]): any;
};
export declare function featuredefinition(name: string, Feature: FeatureClass, options?: BridgeOptions): Definition;
