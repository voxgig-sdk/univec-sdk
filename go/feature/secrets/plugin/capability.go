// VENDORED: @voxgig/plugin 0.1.6 (go/plugin/capability.go)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Capabilities (§11.1).
 *
 * A DEPENDENCY IS ON A CAPABILITY, NOT ON A REF — because it is a
 * dependency on something that can do the job, and which instance is
 * doing it is exactly the configuration detail a plugin must not care
 * about.
 *
 * But A BINDING IS TO AN INSTANCE, not to a capability, which is what
 * decides behaviour when the bound provider leaves while another match
 * remains. */

package plugin

import (
	"sort"
	"strconv"
	"strings"
)

type Provided struct {
	Name     string         `json:"name"`
	Version  string         `json:"version,omitempty"`
	Priority *int           `json:"priority,omitempty"`
	Attrs    map[string]any `json:"attrs,omitempty"`
}

type Required struct {
	Name     string         `json:"name"`
	Range    string         `json:"range,omitempty"`
	Match    map[string]any `json:"match,omitempty"`
	Optional bool           `json:"optional,omitempty"`
	// Policy is §11.3: `static` restarts the consumer when its SELECTED
	// provider leaves, even though another still matches; `dynamic` says
	// in writing that it can survive the swap. Static is the default
	// because most plugins cannot, and the cost of wrongly assuming they
	// can is a live instance holding a dead reference.
	Policy string `json:"policy,omitempty"`
}

type Candidate struct {
	Ref      string   `json:"ref"`
	Pos      int      `json:"pos"`
	Provides Provided `json:"provides"`
}

// ResolveCapability ranks the matching live providers and returns them
// best-first: highest `version`, then LOWEST `priority` (default 0),
// then declaration position `pos` ascending.
//
// `priority` is a field on the capability rather than §7's `order` band,
// because bands live on POINT BINDINGS: a provider may have several
// bindings with different bands, or none at all, so a rank reaching for
// one would be undefined in the common case.
//
// Without a total rank, "any provider satisfies" is true of the GRAPH
// and useless to the PLUGIN — two ports could bind different `store`
// instances, both resolve green, and behave differently, which is
// precisely the divergence a shared corpus exists to catch.
func ResolveCapability(req Required, candidates []Candidate) []Candidate {
	hits := []Candidate{}
	for _, c := range candidates {
		if Matches(req, c.Provides) {
			hits = append(hits, c)
		}
	}
	// SortStable, because the canonical's comparator falls through to
	// `pos` and JavaScript's sort is stable — a Go quicksort would
	// reorder equal-`pos` candidates and diverge on nothing the corpus
	// could name.
	sort.SliceStable(hits, func(i, j int) bool {
		a, b := hits[i], hits[j]
		av, bv := a.Provides.Version, b.Provides.Version
		if av != bv {
			// An ABSENT version sorts last, whatever the other is: the
			// canonical returns 1 for an absent `a` before it ever
			// compares, so "no version" loses to every version rather
			// than being read as 0.0.0.
			if "" == av {
				return false
			}
			if "" == bv {
				return true
			}
			if c := compareversion(bv, av); 0 != c { // highest version FIRST
				return 0 > c
			}
		}
		ap, bp := priorityof(a.Provides), priorityof(b.Provides)
		if ap != bp {
			return ap < bp // lowest priority first
		}
		return a.Pos < b.Pos
	})
	return hits
}

func priorityof(p Provided) int {
	if nil == p.Priority {
		return 0
	}
	return *p.Priority
}

func Matches(req Required, prov Provided) bool {
	if req.Name != prov.Name {
		return false
	}

	if "" != req.Range {
		if "" == prov.Version {
			return false
		}
		if !satisfiesq(prov.Version, req.Range) {
			return false
		}
	}

	// `match` is checked against the provider's `attrs`, key by key. A
	// key the provider does not carry is a miss, not a pass: a
	// requirement asking for `transactional: true` must not be satisfied
	// by a provider that never said.
	if nil != req.Match {
		attrs := prov.Attrs
		if nil == attrs {
			attrs = map[string]any{}
		}
		for k, want := range req.Match {
			got, ok := attrs[k]
			if !ok || !matchvalue(want, got) {
				return false
			}
		}
	}

	return true
}

func compareversion(a string, b string) int {
	pa, pb := parts(a), parts(b)
	for i := 0; i < 3; i++ {
		x, y := at(pa, i), at(pb, i)
		if x != y {
			if x < y {
				return -1
			}
			return 1
		}
	}
	return 0
}

func parts(v string) []int {
	out := []int{}
	for _, s := range strings.Split(v, ".") {
		n, err := strconv.Atoi(s)
		if nil != err {
			n = 0
		}
		out = append(out, n)
	}
	return out
}

/* PARTIAL MATCH, RECURSING INTO MAPS (§11.1).
 *
 * §11.1 says `match` is "a partial match against `attrs`, with exactly
 * the semantics voxgig/struct and the omni corpus already define for
 * `match` — every leaf in the requirement must be present and equal in
 * the capability, keys not mentioned are not checked."
 *
 * THE CANONICAL DID NOT IMPLEMENT THAT. It compared `attrs[k] !==
 * req.match[k]`, which for any compound value is JavaScript reference
 * identity: a requirement and a capability are declared in different
 * places and are never the same object, so `match: {limits: {max: 5}}`
 * could not be satisfied by ANY provider, including one declaring
 * exactly that. The flat reading is invisible while every corpus entry
 * is scalar, which is why P4 found it and P2 did not.
 *
 * Fixed in the canonical (AGENTS.md: change canonical first), pinned by
 * `capability/nested`, and ported here. */
func matchvalue(want any, got any) bool {
	switch w := want.(type) {

	case map[string]any:
		g, ok := got.(map[string]any)
		if !ok {
			return false
		}
		for k, wv := range w {
			gv, present := g[k]
			if !present || !matchvalue(wv, gv) {
				return false
			}
		}
		return true

	case []any:
		g, ok := got.([]any)
		if !ok || len(g) != len(w) {
			return false
		}
		for i := range w {
			if !matchvalue(w[i], g[i]) {
				return false
			}
		}
		return true

	default:
		// GO HAS MANY NUMBER TYPES AND THE MODEL HAS ONE. Corpus JSON
		// decodes every number as float64, but a Go host declaring
		// `Attrs: map[string]any{"max": 5}` writes an int, and `any(5)
		// == any(5.0)` is false — so an attribute that matched in every
		// other port silently missed here. Canonical is type-strict
		// between KINDS (`true` never matches `1`), not between Go's
		// spellings of one kind.
		if wn, wok := numval(want); wok {
			if gn, gok := numval(got); gok {
				return wn == gn
			}
			return false
		}
		return want == got
	}
}

// numval reports a value's numeric value, and whether it had one. `bool`
// is deliberately absent: Go does not make it numeric and neither does
// the model.
func numval(v any) (float64, bool) {
	switch n := v.(type) {
	case int:
		return float64(n), true
	case int8:
		return float64(n), true
	case int16:
		return float64(n), true
	case int32:
		return float64(n), true
	case int64:
		return float64(n), true
	case uint:
		return float64(n), true
	case uint8:
		return float64(n), true
	case uint16:
		return float64(n), true
	case uint32:
		return float64(n), true
	case uint64:
		return float64(n), true
	case float32:
		return float64(n), true
	case float64:
		return n, true
	}
	return 0, false
}
