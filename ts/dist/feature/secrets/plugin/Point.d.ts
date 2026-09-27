export type Kind = 'hook' | 'chain' | 'provider';
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
    band: number;
};
/** Fan-out. Return values are ignored except in `bail`. */
export declare function emit(bindings: Bound[], mode: Mode, arg: any): any;
export declare function compose(bindings: Bound[], base: (...args: any[]) => any): (...args: any[]) => any;
export declare function provider(bindings: Bound[], spec: Spec): {
    winner?: Bound;
    shadowed: string[];
};
