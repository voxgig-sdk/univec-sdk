// VENDORED: @voxgig/plugin 0.1.6 (go/plugin/order.go)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package plugin

import (
	"sort"
	"strings"
)

type Binding struct {
	Ref   string      `json:"ref"`
	Pos   int         `json:"pos"`
	Order *OrderBlock `json:"order,omitempty"`
}

type Pin map[string]string

func ResolveOrder(bindings []Binding, pin Pin) ([]string, error) {
	nodes := append([]Binding{}, bindings...)
	byref := map[string]Binding{}
	for _, b := range nodes {
		byref[b.Ref] = b
	}

	// Constraints are edges. A constraint naming an ABSENT binding is
	// satisfied VACUOUSLY (§7) — a plugin ordered `after: 'test'` must
	// load in a host with no test plugin. That is sdkgen's __after__
	// behaviour, kept.
	edges := map[string][]string{}
	for _, b := range nodes {
		edges[b.Ref] = []string{}
	}

	for _, b := range nodes {
		if nil == b.Order {
			continue
		}
		// An ABSENT constraint and an EMPTY LIST are both "no constraint".
		if declared(b.Order.After) {
			for _, t := range targets(b.Order.After, nodes) {
				edges[t] = append(edges[t], b.Ref)
			}
		}
		if declared(b.Order.Before) {
			for _, t := range targets(b.Order.Before, nodes) {
				edges[b.Ref] = append(edges[b.Ref], t)
			}
		}
	}

	// Stable topological sort. Among ready nodes, band first (lower runs
	// first), then `pos` — the position the DOCUMENT visibly states, not
	// the order instances happened to load and not the incarnation `seq`.
	indeg := map[string]int{}
	for _, b := range nodes {
		indeg[b.Ref] = 0
	}
	for _, from := range sortedkeys(edges) {
		for _, to := range edges[from] {
			indeg[to] = indeg[to] + 1
		}
	}

	out := []string{}
	ready := []Binding{}
	for _, b := range nodes {
		if 0 == indeg[b.Ref] {
			ready = append(ready, b)
		}
	}

	for 0 < len(ready) {
		sort.SliceStable(ready, rankless(ready))
		next := ready[0]
		ready = ready[1:]
		out = append(out, next.Ref)
		for _, to := range edges[next.Ref] {
			indeg[to] = indeg[to] - 1
			if 0 == indeg[to] {
				ready = append(ready, byref[to])
			}
		}
	}

	if len(out) != len(nodes) {
		stuck := []string{}
		for _, b := range nodes {
			if !hasstring(out, b.Ref) {
				stuck = append(stuck, b.Ref)
			}
		}
		return nil, Fail("plugin_order_cycle",
			"before/after constraints cycle: "+strings.Join(stuck, " -> "),
			map[string]any{"cycle": stuck})
	}

	return applypin(out, edges, pin)
}

func rankless(l []Binding) func(i, j int) bool {
	return func(i, j int) bool {
		a, b := l[i], l[j]
		if ab, bb := band(a), band(b); ab != bb {
			return ab < bb
		}
		return a.Pos < b.Pos
	}
}

func band(b Binding) int {
	if nil == b.Order || nil == b.Order.Band {
		return 0
	}
	return *b.Order.Band
}

func targets(spec OrderRef, nodes []Binding) []string {
	hit := []string{}
	// A list fans out to the UNION of what each spelling names, so
	// `after: ['a','b']` means after BOTH, and the same instance named
	// twice - once by name, once by ref - is one edge, not two.
	for _, one := range spec.list {
		for _, b := range nodes {
			if seen(hit, b.Ref) {
				continue
			}
			if b.Ref == one {
				hit = append(hit, b.Ref)
				continue
			}
			if refname(b.Ref) == one {
				hit = append(hit, b.Ref)
			}
		}
	}
	return hit
}

// declared: was a constraint actually stated? An empty list is not one.
func declared(spec OrderRef) bool {
	for _, one := range spec.list {
		if "" != one {
			return true
		}
	}
	return false
}

func seen(hit []string, ref string) bool {
	for _, h := range hit {
		if h == ref {
			return true
		}
	}
	return false
}

func applypin(order []string, edges map[string][]string, pin Pin) ([]string, error) {
	if nil == pin {
		return order, nil
	}
	out := append([]string{}, order...)

	for _, name := range sortedkeys(pin) {
		want := pin[name]
		idx := -1
		for i, r := range out {
			if refname(r) == name {
				idx = i
				break
			}
		}
		if -1 == idx {
			continue
		}

		wantfirst := "first" == want || "outermost" == want
		ref := out[idx]
		out = append(out[:idx], out[idx+1:]...)
		if wantfirst {
			out = append([]string{ref}, out...)
		} else {
			out = append(out, ref)
		}
	}

	// Now check that the placement did not break a constraint. This is
	// the half that makes a pin a rejection rather than an override: the
	// host wins on position, but it does not get to silently discard a
	// relationship a plugin declared.
	at := map[string]int{}
	for i, r := range out {
		at[r] = i
	}
	for _, from := range sortedkeys(edges) {
		for _, to := range edges[from] {
			if at[from] > at[to] {
				return nil, Fail("plugin_order_pinned",
					"a pin would move a binding an ordering constrains: "+
						from+" must precede "+to,
					map[string]any{"before": from, "after": to})
			}
		}
	}

	return out, nil
}
