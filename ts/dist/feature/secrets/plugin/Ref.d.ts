import { Ref } from './Types';
export declare function checkname(name: string): boolean;
export declare function checktag(tag: string): boolean;
export declare function parseref(str: string): Ref;
export declare function formatref(name: string, tag?: string): string;
/** The canonical spelling of a ref. §4 rule 5: ports must canonicalize
 * before comparison. */
export declare function canonref(str: string): string;
export declare function tryref(str: string): string | undefined;
