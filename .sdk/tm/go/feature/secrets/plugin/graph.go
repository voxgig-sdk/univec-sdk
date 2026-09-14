// VENDORED: @voxgig/plugin 0.1.6 (go/plugin/graph.go)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Whole-graph resolution (§11.4) — a phase, not a discovery.
 *
 * "Activate, and wait in `pending` if you must" is correct and, on its
 * own, produces a terrible experience: apply twenty instances against a
 * registry missing one thing and you get NINETEEN pending rows and no
 * statement of what is actually wrong.
 *
 * ResolveGraph is a PURE FUNCTION of the registry and the intended
 * activation set. No callbacks run, no state changes, nothing is
 * touched. It answers for the whole graph at once which instances can be
 * live, and for each blocked one THE SPECIFIC REQUIREMENT that is
 * unmet, and why.
 *
 * The failure mode being designed against is a famous one: OSGi's
 * resolver is correct and its diagnostics are legendarily unusable. A
 * resolver that says "blocked" without saying WHY has moved the problem
 * rather than solved it, so `why` is part of the contract and the
 * corpus pins its shape. */

package plugin

import "sort"

type Node struct {
	Ref      string     `json:"ref"`
	Pos      int        `json:"pos"`
	Provides []Provided `json:"provides,omitempty"`
	Requires []Required `json:"requires,omitempty"`
}

type Blocked struct {
	Ref string `json:"ref"`
	// Unmet is the capability name that could not be satisfied.
	Unmet string `json:"unmet"`
	Why   Why    `json:"why"`
}

// Why is the tagged union §11.4 pins. Go has no sum type, so the fields
// carry `omitempty` and the corpus pins which are present per `kind` —
// the same discrimination the canonical gets from its union.
type Why struct {
	Kind string `json:"kind"`
	// kind: version
	Range string   `json:"range,omitempty"`
	Found []string `json:"found,omitempty"`
	// kind: match
	Failing string `json:"failing,omitempty"`
	Want    any    `json:"want,omitempty"`
	// FoundValue is `found` for kind: match, which is a VALUE and not a
	// list — the two `found` fields cannot share a Go field, and the
	// custom marshaller below is what keeps one JSON name for both.
	FoundValue any `json:"-"`
	// kind: blocked
	Chain []string `json:"chain,omitempty"`
}

// MarshalJSON exists for one reason: `why.found` is a LIST OF VERSIONS
// under `kind: version` and a SINGLE ATTRIBUTE VALUE under `kind:
// match`. The canonical's union gives each variant its own `found`;
// Go's struct cannot, so the two are separate fields that render to one
// name. A `found` of `false` or `null` under `kind: match` must still
// appear, which is why it is not merely another omitempty field.
func (w Why) MarshalJSON() ([]byte, error) {
	out := map[string]any{"kind": w.Kind}
	switch w.Kind {
	case "version":
		out["range"] = w.Range
		out["found"] = w.Found
	case "match":
		out["failing"] = w.Failing
		out["want"] = w.Want
		out["found"] = w.FoundValue
	case "blocked":
		out["chain"] = w.Chain
	}
	return marshal(out)
}

type Resolution struct {
	Resolved []string  `json:"resolved"`
	Blocked  []Blocked `json:"blocked"`
}

func ResolveGraph(nodes []Node) Resolution {
	byref := map[string]Node{}
	for _, n := range nodes {
		byref[n.Ref] = n
	}

	resolved := map[string]bool{}
	blocked := map[string]Blocked{}

	// Fixed point: a node resolves when every mandatory requirement is
	// met by an ALREADY-RESOLVED provider. Iterating to a fixed point is
	// what makes a provider that is itself blocked propagate, rather
	// than each node being judged against the raw registry.
	for moved := true; moved; {
		moved = false
		for _, n := range nodes {
			if resolved[n.Ref] {
				continue
			}
			if _, bad := firstunmet(n, byref, resolved); !bad {
				resolved[n.Ref] = true
				moved = true
			}
		}
	}

	for _, n := range nodes {
		if resolved[n.Ref] {
			continue
		}
		if why, bad := firstunmet(n, byref, resolved); bad {
			blocked[n.Ref] = why
		}
	}

	res := Resolution{Resolved: []string{}, Blocked: []Blocked{}}
	for r := range resolved {
		res.Resolved = append(res.Resolved, r)
	}
	sort.Strings(res.Resolved)
	for _, r := range sortedkeys(blocked) {
		res.Blocked = append(res.Blocked, blocked[r])
	}
	return res
}

// firstunmet returns the FIRST unmet requirement, with the most specific
// explanation available. Order matters: "no provider at all" and "a
// provider at the wrong version" are different problems and a reader
// must not have to guess which they have.
//
// The second return is the canonical's `null` — Go has no nullable
// struct without a pointer, and a bool says what it means.
func firstunmet(n Node, byref map[string]Node, resolved map[string]bool) (Blocked, bool) {
	for _, req := range n.Requires {
		if req.Optional {
			continue
		}

		all := graphcandidates(byref, req.Name)
		if 0 == len(all) {
			return Blocked{Ref: n.Ref, Unmet: req.Name, Why: Why{Kind: "absent"}}, true
		}

		ok := ResolveCapability(req, all)
		if 0 < len(ok) {
			// A provider exists and matches — but if none of them is
			// itself resolved, this node is blocked BEHIND it, and the
			// chain is the useful answer rather than "unmet".
			live := false
			chain := []string{}
			for _, c := range ok {
				chain = append(chain, c.Ref)
				if resolved[c.Ref] {
					live = true
				}
			}
			if live {
				continue
			}
			sort.Strings(chain)
			return Blocked{Ref: n.Ref, Unmet: req.Name,
				Why: Why{Kind: "blocked", Chain: chain}}, true
		}

		// Providers exist and none matched. Say which test failed.
		if "" != req.Range {
			versions := []string{}
			for _, c := range all {
				if "" == c.Provides.Version {
					versions = append(versions, "(none)")
				} else if !satisfiesq(c.Provides.Version, req.Range) {
					versions = append(versions, c.Provides.Version)
				}
			}
			if 0 < len(versions) {
				sort.Strings(versions)
				return Blocked{Ref: n.Ref, Unmet: req.Name,
					Why: Why{Kind: "version", Range: req.Range, Found: versions}}, true
			}
		}

		if nil != req.Match {
			for _, c := range all {
				attrs := c.Provides.Attrs
				if nil == attrs {
					attrs = map[string]any{}
				}
				for _, k := range sortedkeys(req.Match) {
					got, present := attrs[k]
					if !present || !matchvalue(req.Match[k], got) {
						var found any
						if present {
							found = got
						}
						return Blocked{Ref: n.Ref, Unmet: req.Name,
							Why: Why{Kind: "match", Failing: k,
								Want: req.Match[k], FoundValue: found}}, true
					}
				}
			}
		}

		return Blocked{Ref: n.Ref, Unmet: req.Name, Why: Why{Kind: "absent"}}, true
	}
	return Blocked{}, false
}

func graphcandidates(byref map[string]Node, name string) []Candidate {
	out := []Candidate{}
	// A NODE SATISFIES ITS OWN REF (§11.1), and the graph learned it
	// here. Considering only declared capabilities made Resolve answer
	// `absent` about a provider sitting right there and live — §11.4's
	// job is explaining the graph the runtime reconciles, and it was
	// explaining a different one.
	asref := canon(name)
	for _, ref := range sortedkeys(byref) {
		n := byref[ref]
		// The ref match WINS OUTRIGHT for that node, as at runtime: one
		// candidate, not two, for a node both named `b` and providing `b`.
		if ref == asref {
			out = append(out, Candidate{Ref: n.Ref, Pos: n.Pos, Provides: Provided{Name: name}})
			continue
		}
		for _, p := range n.Provides {
			if p.Name == name {
				out = append(out, Candidate{Ref: n.Ref, Pos: n.Pos, Provides: p})
			}
		}
	}
	return out
}
