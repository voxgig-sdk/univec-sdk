import { Required } from './Capability';
/** A bare string is shorthand for `{name}`. */
export declare function normrequire(r: any): Required;
export declare function requirements(options: any): Required[];
export declare function restartsonloss(r: Required): boolean;
export declare function gatesactivation(r: Required): boolean;
export declare function restartcausing(r: Required): boolean;
export type Node = {
    ref: string;
    provides: string[];
    requires: Required[];
};
export declare function dependencycycle(nodes: Node[]): string[] | null;
/** Raise on a cycle, naming it. Separate from the detector so the
 * detector stays pure and corpus-testable. */
export declare function checkcycle(nodes: Node[]): void;
