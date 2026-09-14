import { Required } from './Capability';
/** A bare string is shorthand for `{name}`. */
export declare function normrequire(r: any): Required;
/** The requirements a definition declared, normalized.
 *
 * BOTH AXES ARE READ AT TWO LEVELS, AND THE PER-REQUIREMENT ONE WINS.
 *
 * The instance-level `policy` and `optional` list are how a DOCUMENT
 * states the axis without editing the definition, and they apply to
 * every requirement. The per-requirement form is the one §11.1's object
 * syntax exists for, and it is strictly more expressive: an instance
 * that is `static` on its store and `dynamic` on its metrics cannot be
 * written at all at the instance level, and that is the ordinary case
 * rather than an exotic one.
 *
 * `optional` unions rather than overriding — both spellings are
 * statements that this requirement need not gate activation, and there
 * is no reading under which one of them means "actually, mandatory". */
export declare function requirements(options: any): Required[];
/** Does losing this requirement's SELECTED provider restart the
 * consumer? The mandatory ones under `static`, and the `static`
 * optional ones — both make a capability change deactivate and
 * reactivate. `dynamic` never restarts: mandatory-dynamic stays live
 * and is notified, optional-dynamic is a notification and nothing
 * else. */
export declare function restartsonloss(r: Required): boolean;
/** Does an unmet requirement keep the consumer out of `live`?
 *
 * Cardinality alone decides this, NOT policy. `dynamic` is a statement
 * about surviving a SWAP, not about starting without the thing at all —
 * a mandatory-dynamic consumer still waits in `pending` for its first
 * provider. Conflating the two would let a plugin that declared it can
 * cope with replacement activate with nothing to call. */
export declare function gatesactivation(r: Required): boolean;
/** Edges that can cause a restart, which is exactly the set a cycle
 * must be detected over (§11.3).
 *
 * Those are the mandatory requirements AND THE `static` OPTIONAL ONES,
 * because both make a capability change deactivate and reactivate the
 * consumer — and a cycle of restarts does not settle: A comes up, B
 * restarts, which changes B's capability, which restarts A,
 * indefinitely.
 *
 * ONLY `dynamic` OPTIONAL EDGES ARE EXCLUDED, and they are the ones the
 * exclusion was for: two plugins that optionally and dynamically
 * consume each other's capabilities both activate happily, neither
 * gates on the other, and each is merely notified when the other
 * appears. Nothing restarts, so nothing oscillates.
 *
 * An earlier draft of §11.3 excluded EVERY optional edge and thereby
 * admitted the non-terminating case it was trying to permit. */
export declare function restartcausing(r: Required): boolean;
export type Node = {
    ref: string;
    provides: string[];
    requires: Required[];
};
/** A cycle through restart-causing requirements is
 * `plugin_dependency_cycle`, detected AT LOAD — before anything runs,
 * because the failure it describes is a non-terminating reconcile and
 * the only safe time to report that is before it starts.
 *
 * The graph is over capabilities, not refs: an edge runs from a
 * consumer to EVERY node that provides what it needs, because any of
 * them could be the one selected and a cycle through any is a cycle.
 * A node also satisfies its own name as a ref (§11.1), which is why the
 * ref is a provider of itself here. */
export declare function dependencycycle(nodes: Node[]): string[] | null;
/** Raise on a cycle, naming it. Separate from the detector so the
 * detector stays pure and corpus-testable. */
export declare function checkcycle(nodes: Node[]): void;
