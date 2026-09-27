export type Ref = {
    name: string;
    tag: string;
};
export type Status = 'declared' | 'loaded' | 'pending' | 'live' | 'failed' | 'loading' | 'closing';
/** A normalized instance entry. Option data is NOT merged here — see
 * `optionlayers`. */
export type Instance = {
    pos: number;
    active: boolean;
    start: 'eager' | 'lazy';
    order?: OrderBlock;
    optionlayers: any[];
};
export type OrderRef = string | string[];
export type OrderSpec = OrderRef | null;
export type OrderBlock = {
    before?: OrderSpec;
    after?: OrderSpec;
    band?: number;
};
export type Normalized = {
    instance: {
        [ref: string]: Instance;
    };
    order: string[];
    default: {
        [name: string]: any;
    };
};
export declare const DETAIL_ORDER: string[];
/** `plugin/<code>: <text> [<key>=<value> …]`
 *
 * Values render as COMPACT JSON, so a value containing a space or a
 * bracket cannot break the parse, and a list renders as a JSON array.
 * The bracket is absent entirely when no field applies. */
export declare function formaterror(code: string, text: string, details?: {
    [k: string]: any;
}): string;
export declare class PluginError extends Error {
    code: string;
    text: string;
    details: {
        [k: string]: any;
    };
    constructor(code: string, text: string, details?: {
        [k: string]: any;
    });
}
export declare function fail(code: string, text: string, details?: any): never;
