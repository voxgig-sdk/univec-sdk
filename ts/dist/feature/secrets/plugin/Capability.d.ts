export type Provided = {
    name: string;
    version?: string;
    priority?: number;
    attrs?: {
        [k: string]: any;
    };
};
export type Required = {
    name: string;
    range?: string;
    match?: {
        [k: string]: any;
    };
    optional?: boolean;
    /** §11.3: `static` restarts the consumer when its SELECTED provider
     * leaves, even though another still matches; `dynamic` says in
     * writing that it can survive the swap. Static is the default because
     * most plugins cannot, and the cost of wrongly assuming they can is a
     * live instance holding a dead reference. */
    policy?: 'static' | 'dynamic';
};
export type Candidate = {
    ref: string;
    pos: number;
    provides: Provided;
};
/** Rank the matching live providers and return them best-first:
 * highest `version`, then LOWEST `priority` (default 0), then
 * declaration position `pos` ascending.
 *
 * `priority` is a field on the capability rather than §7's `order`
 * band, because bands live on POINT BINDINGS: a provider may have
 * several bindings with different bands, or none at all, so a rank
 * reaching for one would be undefined in the common case.
 *
 * Without a total rank, "any provider satisfies" is true of the GRAPH
 * and useless to the PLUGIN — two ports could bind different `store`
 * instances, both resolve green, and behave differently, which is
 * precisely the divergence a shared corpus exists to catch. */
export declare function resolvecapability(req: Required, candidates: Candidate[]): Candidate[];
export declare function matches(req: Required, prov: Provided): boolean;
/** PARTIAL MATCH, RECURSING INTO MAPS (§11.1).
 *
 * §11.1 defines `match` as "a partial match against `attrs`, with
 * exactly the semantics voxgig/struct and the omni corpus already
 * define for `match` — every leaf in the requirement must be present
 * and equal in the capability, keys not mentioned are not checked."
 *
 * THIS FUNCTION IS WHAT "EVERY LEAF" MEANS, and an earlier draft did
 * not have it: the check was `attrs[k] !== req.match[k]`, which for any
 * compound value is JavaScript REFERENCE IDENTITY. A requirement and a
 * capability are declared in different places and are never the same
 * object, so `match: {limits: {max: 5}}` could not be satisfied by any
 * provider at all — including one declaring exactly that. The flat
 * reading is invisible while every corpus entry is scalar, which is why
 * the go port found it and P2 did not.
 *
 * A LIST IS COMPARED LEAF-WISE AT THE SAME LENGTH, not as a subset.
 * "the first two of your three regions" is not something `match` can
 * say, and inventing a spelling for it would be inventing the filter
 * language §11.1 explicitly declines to add. */
export declare function matchvalue(want: any, got: any): boolean;
