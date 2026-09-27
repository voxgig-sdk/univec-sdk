export type EnvResult = {
    profile?: string;
    options: {
        [ref: string]: any;
    };
    active: string[];
    inactive: string[];
};
export type EnvInput = {
    env: {
        [k: string]: string;
    };
    refs?: string[];
    reserved?: string[];
};
export declare function encoderef(ref: string): string;
export declare function applyenv(input: EnvInput): EnvResult;
