import { Provided, Required } from './Capability';
export type Node = {
    ref: string;
    pos: number;
    provides?: Provided[];
    requires?: Required[];
};
export type Blocked = {
    ref: string;
    /** The capability name that could not be satisfied. */
    unmet: string;
    why: Why;
};
export type Why = {
    kind: 'absent';
} | {
    kind: 'version';
    range: string;
    found: string[];
} | {
    kind: 'match';
    failing: string;
    want: any;
    found: any;
} | {
    kind: 'blocked';
    chain: string[];
};
export type Resolution = {
    resolved: string[];
    blocked: Blocked[];
};
export declare function resolvegraph(nodes: Node[]): Resolution;
