import { Normalized } from './Types';
export type NormalizeInput = {
    doc: any;
    profile?: string;
    keys?: {
        instance?: string;
        default?: string;
    };
    reserved?: string[];
};
export declare function normalizeconfig(input: NormalizeInput): Normalized;
export type ResolveInput = {
    ref: string;
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
