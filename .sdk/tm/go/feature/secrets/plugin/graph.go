// VENDORED: @voxgig/plugin 0.1.6 (go/plugin/graph.go)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
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
