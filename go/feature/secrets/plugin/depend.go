// VENDORED: @voxgig/plugin 0.1.6 (go/plugin/depend.go)
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
 * because most plugins cannot, and the cost of wrongly assuming they can
 * is a live instance holding a dead reference.
 *
 * The rebinding-preference axis is deliberately omitted. OSGi has
 * reluctant vs greedy and it is a knob every author must understand to
 * read anyone else's component; we take always-reluctant. Three axes
 * were more than the model can carry across twenty ports. */

package plugin

import "sort"

// NormRequire: a bare string is shorthand for `{name}`.
func NormRequire(r any) Required {
	if s, ok := r.(string); ok {
		return Required{Name: s}
	}
	m := asmap(r)
	out := Required{
		Name:   asstring(m["name"], ""),
		Range:  asstring(m["range"], ""),
		Policy: asstring(m["policy"], ""),
	}
	if v, ok := m["match"].(map[string]any); ok {
		out.Match = v
	}
	out.Optional = asbool(m["optional"], false)
	return out
}

/* Requirements are the requirements a definition declared, normalized.
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
func Requirements(options map[string]any) []Required {
	raw, _ := aslist(options["requires"])
	markedraw, _ := aslist(options["optional"])
	marked := []string{}
	for _, m := range markedraw {
		marked = append(marked, asstring(m, ""))
	}
	fallback := asstring(options["policy"], "")

	out := []Required{}
	for _, r := range raw {
		req := NormRequire(r)
		if req.Optional || hasstring(marked, req.Name) {
			req.Optional = true
		}
		if "" == req.Policy && "" != fallback {
			req.Policy = fallback
		}
		out = append(out, req)
	}
	return out
}

// RestartsOnLoss: does losing this requirement's SELECTED provider
// restart the consumer? The mandatory ones under `static`, and the
// `static` optional ones — both make a capability change deactivate and
// reactivate. `dynamic` never restarts: mandatory-dynamic stays live and
// is notified, optional-dynamic is a notification and nothing else.
func RestartsOnLoss(r Required) bool {
	policy := r.Policy
	if "" == policy {
		policy = "static"
	}
	return "dynamic" != policy
}

// GatesActivation: does an unmet requirement keep the consumer out of
// `live`?
//
// Cardinality alone decides this, NOT policy. `dynamic` is a statement
// about surviving a SWAP, not about starting without the thing at all —
// a mandatory-dynamic consumer still waits in `pending` for its first
// provider. Conflating the two would let a plugin that declared it can
// cope with replacement activate with nothing to call.
func GatesActivation(r Required) bool {
	return !r.Optional
}

/* RestartCausing marks the edges that can cause a restart, which is
 * exactly the set a cycle must be detected over (§11.3).
 *
 * Those are the mandatory requirements AND THE `static` OPTIONAL ONES,
 * because both make a capability change deactivate and reactivate the
 * consumer — and a cycle of restarts does not settle: A comes up, B
 * restarts, which changes B's capability, which restarts A,
 * indefinitely.
 *
 * ONLY `dynamic` OPTIONAL EDGES ARE EXCLUDED, and they are the ones the
 * exclusion was for: two plugins that optionally and dynamically consume
 * each other's capabilities both activate happily, neither gates on the
 * other, and each is merely notified when the other appears. Nothing
 * restarts, so nothing oscillates.
 *
 * An earlier draft of §11.3 excluded EVERY optional edge and thereby
 * admitted the non-terminating case it was trying to permit. */
func RestartCausing(r Required) bool {
	return GatesActivation(r) || RestartsOnLoss(r)
}

// DependNode is the requirement graph as plain data, for the pure
// detector.
type DependNode struct {
	Ref      string
	Provides []string
	Requires []Required
}

/* DependencyCycle: a cycle through restart-causing requirements is
 * `plugin_dependency_cycle`, detected AT LOAD — before anything runs,
 * because the failure it describes is a non-terminating reconcile and
 * the only safe time to report that is before it starts.
 *
 * The graph is over capabilities, not refs: an edge runs from a consumer
 * to EVERY node that provides what it needs, because any of them could
 * be the one selected and a cycle through any is a cycle. A node also
 * satisfies its own name as a ref (§11.1), which is why the ref is a
 * provider of itself here. */
func DependencyCycle(nodes []DependNode) []string {
	// TWO INDEXES, NOT ONE MERGED MAP. Capability names and refs are
	// matched differently — a capability by its exact name, a ref through
	// the canonical spelling (§4 rule 5) — and one map keyed by both can
	// only do one of them. Keyed by both and looked up raw, as this was,
	// a cycle spelled `a$`/`b$` found no providers and EVADED the
	// load-time check that exists to catch a non-terminating reconcile.
	bycap := map[string][]string{}
	isref := map[string]bool{}
	for _, n := range nodes {
		isref[n.Ref] = true
		for _, cap := range n.Provides {
			bycap[cap] = append(bycap[cap], n.Ref)
		}
	}

	edges := map[string][]string{}
	for _, n := range nodes {
		out := []string{}
		for _, r := range n.Requires {
			if !RestartCausing(r) {
				continue
			}
			from := append([]string{}, bycap[r.Name]...)
			// A node satisfies its own name AS A REF (§11.1),
			// canonically — exactly what `providersof` does at runtime,
			// so the load-time graph and the running one agree about
			// what an edge is. `canon` hands back a name no ref could
			// have unchanged, and no instance ref can equal one, so it
			// is the tolerant test this needs.
			if asref := canon(r.Name); isref[asref] && !hasstring(from, asref) {
				from = append(from, asref)
			}
			for _, p := range from {
				if p != n.Ref && !hasstring(out, p) {
					out = append(out, p)
				}
			}
		}
		sort.Strings(out)
		edges[n.Ref] = out
	}

	// Iterative DFS with an explicit stack: twenty ports, and several of
	// them have no recursion budget worth relying on.
	const white, grey, black = 0, 1, 2
	colour := map[string]int{}
	for _, n := range nodes {
		colour[n.Ref] = white
	}

	for _, start := range sortedkeys(edges) {
		if white != colour[start] {
			continue
		}
		path := []string{start}
		type frame struct {
			ref string
			i   int
		}
		stack := []frame{{ref: start, i: 0}}
		colour[start] = grey

		for 0 < len(stack) {
			top := &stack[len(stack)-1]
			if top.i >= len(edges[top.ref]) {
				colour[top.ref] = black
				stack = stack[:len(stack)-1]
				path = path[:len(path)-1]
				continue
			}
			next := edges[top.ref][top.i]
			top.i++
			if grey == colour[next] {
				// Report the cycle itself, not the walk that found it.
				return append(append([]string{}, path[indexof(path, next):]...), next)
			}
			if black == colour[next] {
				continue
			}
			colour[next] = grey
			path = append(path, next)
			stack = append(stack, frame{ref: next, i: 0})
		}
	}
	return nil
}

// CheckCycle raises on a cycle, naming it. Separate from the detector so
// the detector stays pure and corpus-testable.
func CheckCycle(nodes []DependNode) error {
	if cycle := DependencyCycle(nodes); nil != cycle {
		return Fail("plugin_dependency_cycle",
			"requirements cycle: "+join(cycle, " -> "),
			map[string]any{"cycle": cycle})
	}
	return nil
}
