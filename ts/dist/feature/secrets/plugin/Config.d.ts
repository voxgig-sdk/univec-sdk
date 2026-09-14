import { Normalized } from './Types';
export type NormalizeInput = {
    doc: any;
    profile?: string;
    /** §9.1: a host may rename `instance` and `default` into its own
     * vocabulary. */
    keys?: {
        instance?: string;
        default?: string;
    };
    /** §9.1: refs the host declares itself and always wins on. */
    reserved?: string[];
};
export declare function normalizeconfig(input: NormalizeInput): Normalized;
export type ResolveInput = {
    ref: string;
    /** Level 1 — the definition's option shape. Also carries the $MERGE
     * directives, which is why merging cannot happen without it. */
    shape?: any;
    hostdefaults?: any;
    doc?: any;
    profile?: string;
    env?: any;
    hostoptions?: any;
    loadoptions?: any;
    patch?: any;
};
export declare function resolveoptions(input: ResolveInput): any;
export declare function checkshape(shape: any): void;
