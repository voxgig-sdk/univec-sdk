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
    /** Every ref the host holds. Needed because the encoding is lossy:
     * without the set there is no way to know where the ref ends and the
     * path begins in `RETRY__FAST_MIN_DELAY`. */
    refs?: string[];
    reserved?: string[];
};
/** `retry$fast` -> `RETRY__FAST`. */
export declare function encoderef(ref: string): string;
export declare function applyenv(input: EnvInput): EnvResult;
