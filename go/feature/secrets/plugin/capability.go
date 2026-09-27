// VENDORED: @voxgig/plugin 0.1.6 (go/plugin/capability.go)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
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
	Policy   string         `json:"policy,omitempty"`
}

type Candidate struct {
	Ref      string   `json:"ref"`
	Pos      int      `json:"pos"`
	Provides Provided `json:"provides"`
}

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
		if wn, wok := numval(want); wok {
			if gn, gok := numval(got); gok {
				return wn == gn
			}
			return false
		}
		return want == got
	}
}

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
