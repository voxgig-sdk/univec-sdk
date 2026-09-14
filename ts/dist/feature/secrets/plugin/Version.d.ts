export type Range = {
    lo: number[];
    hi: number[];
};
/** Two forms and no more (§11.2):
 *
 *   '2.1'    >= 2.1.0 and < 3.0.0
 *   '~2.1'   >= 2.1.0 and < 2.2.0
 */
export declare function parserange(range: string): Range;
export declare function parseversion(version: string): number[];
/** The one satisfaction predicate: lo <= version < hi. */
export declare function satisfies(version: string, range: string): boolean;
export declare function cmp(a: number[], b: number[]): number;
