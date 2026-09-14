/** The two halves of an identity (§4). `tag` is '' when absent — never
 * null and never missing, because a port returning three shapes for two
 * states makes every downstream comparison a special case. */
export type Ref = {
    name: string;
    tag: string;
};
/** §5.1's seven statuses, and no more. A port that adds an eighth is
 * diverging. `loading` and `closing` are observable only from inside a
 * callback or from another thread. */
export type Status = 'declared' | 'loaded' | 'pending' | 'live' | 'failed' | 'loading' | 'closing';
/** A normalized instance entry. Option data is NOT merged here — see
 * `optionlayers`. */
export type Instance = {
    pos: number;
    active: boolean;
    start: 'eager' | 'lazy';
    order?: OrderBlock;
    /** Levels 3-6 that are present, IN LADDER ORDER (§9.3).
     *
     * Normalization does not merge these, and cannot: §9.4 makes merge
     * behaviour a property of the definition's option shape, which
     * normalization has never seen. Flattening them here would make
     * `$MERGE: append` unimplementable at load time, because the layers
     * it must concatenate would already be collapsed. */
    optionlayers: any[];
};
/** §4.4 of DOCS.md — `band` rather than a nested `order`, because
 * `order.order` needs explaining every time it is read. */
/** `before`/`after` accept ONE spelling or a LIST of them. The list form
 * is not decoration: a host may need a binding after two unrelated others,
 * and station's per-feature `order` has carried string lists since Stage 3b.
 * Plugin typed this as a bare string and matched with `===`, so a list was
 * SILENTLY DROPPED - the sort came out exactly as if no constraint had been
 * declared, with nothing raised. */
export type OrderRef = string | string[];
/** What a NORMALIZED block may hold, which is wider than what constrains
 * anything. Normalization is a carrier, not an interpreter (§9.1): the
 * block comes back exactly as authored, so a value written `null` is still
 * `null` here, and `config/normorder#null-survives` pins that. Typing it
 * as `OrderRef | undefined` told callers a runtime null was impossible
 * while `Config.ts` assigned one straight through `any`. `declared()` is
 * the gate that turns a spec into a constraint; nothing else may assume
 * one. */
export type OrderSpec = OrderRef | null;
export type OrderBlock = {
    before?: OrderSpec;
    after?: OrderSpec;
    band?: number;
};
export type Normalized = {
    instance: {
        [ref: string]: Instance;
    };
    order: string[];
    default: {
        [name: string]: any;
    };
};
/** §12's detail fields, IN THIS FIXED ORDER.
 *
 * The order is part of the contract, not a formatting preference. An
 * earlier draft named six fields while other sections promised
 * diagnostics that had nowhere to go, which would have left each port
 * inventing its own order and breaking message parity. */
export declare const DETAIL_ORDER: string[];
/** `plugin/<code>: <text> [<key>=<value> …]`
 *
 * Values render as COMPACT JSON, so a value containing a space or a
 * bracket cannot break the parse, and a list renders as a JSON array.
 * The bracket is absent entirely when no field applies. */
export declare function formaterror(code: string, text: string, details?: {
    [k: string]: any;
}): string;
/** Every error carries a §12 code. Ports compare by CODE and never by
 * message: wording is a port's own business, and pinning the words
 * would make every translation a corpus change. The FORMAT, however, is
 * pinned — a parseable message is what makes a log searchable across
 * twenty languages. */
export declare class PluginError extends Error {
    code: string;
    text: string;
    details: {
        [k: string]: any;
    };
    constructor(code: string, text: string, details?: {
        [k: string]: any;
    });
}
export declare function fail(code: string, text: string, details?: any): never;
