export type Range = {
    lo: number[];
    hi: number[];
};
export declare function parserange(range: string): Range;
export declare function parseversion(version: string): number[];
/** The one satisfaction predicate: lo <= version < hi. */
export declare function satisfies(version: string, range: string): boolean;
export declare function cmp(a: number[], b: number[]): number;
