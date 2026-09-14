// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/Depend.ts)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Dependency cardinality, policy, and the restart graph (§11.3).
 *
 * TWO AXES, BOTH DECLARED BY THE DEFINITION THAT HAS THE REQUIREMENT,
 * because only it knows what it can cope with:
 *
 *                | static (default)          | dynamic
 *   -------------|---------------------------|--------------------------
 *   mandatory    | unmet -> pending;         | unmet -> pending;
 *   (default)    | lost  -> pending,         | lost  -> STAYS LIVE,
 *                |          recursively      |          notified
 *   -------------|---------------------------|--------------------------
 *   optional:true| never gates activation;   | never gates activation;
 *                | a change deactivates and  | a change is a
 *                | reactivates               | notification, nothing else
 *
 * `dynamic` means the plugin has said, IN WRITING, that it can survive
 * its provider being swapped underneath it. It is not the default
 * because most plugins cannot, and the cost of wrongly assuming they
 * can is a live instance holding a dead reference.
 *
 * The rebinding-preference axis is deliberately omitted. OSGi has
 * reluctant vs greedy and it is a knob every author must understand to
 * read anyone else's component; we take always-reluctant. Three axes
 * were more than the model can carry across twenty ports. */

import { Required } from './Capability'
import { tryref } from './Ref'
import { fail } from './Types'

/** A bare string is shorthand for `{name}`. */
export function normrequire(r: any): Required {
  return ('string' === typeof r ? { name: r } : (r || {})) as Required
}

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
export function requirements(options: any): Required[] {
  const raw: any[] = (options && options.requires) || []
  const marked: string[] = (options && options.optional) || []
  const fallback = options && options.policy
  return raw.map(normrequire).map((r) => {
    const out: Required = { ...r }
    if (r.optional || -1 !== marked.indexOf(r.name)) { out.optional = true }
    if (undefined === out.policy && undefined !== fallback) {
      out.policy = fallback
    }
    return out
  })
}

/** Does losing this requirement's SELECTED provider restart the
 * consumer? The mandatory ones under `static`, and the `static`
 * optional ones — both make a capability change deactivate and
 * reactivate. `dynamic` never restarts: mandatory-dynamic stays live
 * and is notified, optional-dynamic is a notification and nothing
 * else. */
export function restartsonloss(r: Required): boolean {
  return 'dynamic' !== (r.policy || 'static')
}

/** Does an unmet requirement keep the consumer out of `live`?
 *
 * Cardinality alone decides this, NOT policy. `dynamic` is a statement
 * about surviving a SWAP, not about starting without the thing at all —
 * a mandatory-dynamic consumer still waits in `pending` for its first
 * provider. Conflating the two would let a plugin that declared it can
 * cope with replacement activate with nothing to call. */
export function gatesactivation(r: Required): boolean {
  return true !== r.optional
}

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
export function restartcausing(r: Required): boolean {
  return gatesactivation(r) || restartsonloss(r)
}

export type Node = {
  ref: string
  provides: string[]
  requires: Required[]
}

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
export function dependencycycle(nodes: Node[]): string[] | null {
  // TWO INDEXES, NOT ONE MERGED MAP. Capability names and refs are
  // matched differently — a capability by its exact name, a ref through
  // the canonical spelling (§4 rule 5) — and a single map keyed by both
  // can only do one of them. Keyed by both and looked up raw, as this
  // was, a cycle spelled `a$`/`b$` found no providers and EVADED the
  // load-time check that exists to catch a non-terminating reconcile:
  // the same graph, written two ways, gave two answers.
  const bycap: { [cap: string]: string[] } = {}
  const isref: { [ref: string]: boolean } = {}
  for (const n of nodes) {
    isref[n.ref] = true
    for (const cap of n.provides) {
      (bycap[cap] = bycap[cap] || []).push(n.ref)
    }
  }

  const edges: { [ref: string]: string[] } = {}
  for (const n of nodes) {
    const out: string[] = []
    for (const r of n.requires) {
      if (!restartcausing(r)) continue
      const from: string[] = (bycap[r.name] || []).slice()
      // A node satisfies its own name AS A REF (§11.1), canonically —
      // exactly what `providersof` does at runtime, so the load-time
      // graph and the running one agree about what an edge is.
      const asref = tryref(r.name)
      if (undefined !== asref && isref[asref] && -1 === from.indexOf(asref)) {
        from.push(asref)
      }
      for (const p of from) {
        if (p !== n.ref && -1 === out.indexOf(p)) out.push(p)
      }
    }
    edges[n.ref] = out.sort()
  }

  // Iterative DFS with an explicit stack: twenty ports, and several of
  // them have no recursion budget worth relying on.
  const WHITE = 0, GREY = 1, BLACK = 2
  const colour: { [ref: string]: number } = {}
  for (const n of nodes) colour[n.ref] = WHITE

  for (const start of Object.keys(edges).sort()) {
    if (WHITE !== colour[start]) continue
    const path: string[] = []
    const stack: { ref: string, i: number }[] = [{ ref: start, i: 0 }]
    colour[start] = GREY
    path.push(start)

    while (0 < stack.length) {
      const top = stack[stack.length - 1]
      const next = edges[top.ref][top.i++]
      if (undefined === next) {
        colour[top.ref] = BLACK
        stack.pop()
        path.pop()
        continue
      }
      if (GREY === colour[next]) {
        // Report the cycle itself, not the walk that found it.
        return path.slice(path.indexOf(next)).concat([next])
      }
      if (BLACK === colour[next]) continue
      colour[next] = GREY
      path.push(next)
      stack.push({ ref: next, i: 0 })
    }
  }
  return null
}

/** Raise on a cycle, naming it. Separate from the detector so the
 * detector stays pure and corpus-testable. */
export function checkcycle(nodes: Node[]): void {
  const cycle = dependencycycle(nodes)
  if (null != cycle) {
    fail('plugin_dependency_cycle',
      'requirements cycle: ' + cycle.join(' -> '), { cycle })
  }
}
