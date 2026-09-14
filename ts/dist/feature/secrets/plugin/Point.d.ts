export type Kind = 'hook' | 'chain' | 'provider';
/** §6.1: "fan-out" is not one answer but four. In a language with
 * asynchrony, "call every binding" hides a decision — start them all
 * and wait, await each in turn, or do not wait — and a design that
 * leaves it unsaid gets four different answers from four ports, in the
 * concurrency behaviour of production code no corpus entry happens to
 * cover. */
export type Mode = 'emit' | 'parallel' | 'serial' | 'bail';
export type Spec = {
    kind?: Kind;
    mode?: Mode;
    /** `chain` only: the host owns the base, and a plugin cannot replace
     * it (§6.2). One that wants to SUBSTITUTE rather than wrap binds
     * innermost and simply does not call `next`. */
    base?: (...args: any[]) => any;
    /** `provider` only: a second binding is an error rather than a
     * shadow. */
    exclusive?: boolean;
    /** `provider` only: the host's fallback. */
    default?: any;
    pin?: {
        [name: string]: 'outermost' | 'innermost' | 'first' | 'last';
    };
};
export type Bound = {
    ref: string;
    point: string;
    fn: any;
    /** `provider` ranks by HIGHEST band, unlike hook and chain which run
     * lowest first. Kept as declared so the two rules stay visibly
     * different rather than one being derived from the other by a reader
     * who then gets it backwards. */
    band: number;
};
/** Fan-out. Return values are ignored except in `bail`. */
export declare function emit(bindings: Bound[], mode: Mode, arg: any): any;
/** Composition: b1(b2(b3(base))), FIRST BINDING OUTERMOST (§6.2).
 *
 * Recomputed by the host whenever the live set changes, and cached
 * between changes. Plugins receive `next` as an argument; they never
 * see or store the previous value of anything. A plugin that stashes
 * `next` and calls it after deactivation is a bug the host cannot
 * prevent, and this says so rather than pretending otherwise. */
export declare function compose(bindings: Bound[], base: (...args: any[]) => any): (...args: any[]) => any;
/** At most one live implementation (§6.3). The winner is the highest
 * band, ties broken by ref sort, and THE LOSERS ARE VISIBLE rather than
 * silently ignored. */
export declare function provider(bindings: Bound[], spec: Spec): {
    winner?: Bound;
    shadowed: string[];
};
