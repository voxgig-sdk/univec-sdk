// VENDORED: @voxgig/plugin 0.1.6 (go/plugin/depend.go)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
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

func RestartsOnLoss(r Required) bool {
	policy := r.Policy
	if "" == policy {
		policy = "static"
	}
	return "dynamic" != policy
}

func GatesActivation(r Required) bool {
	return !r.Optional
}

func RestartCausing(r Required) bool {
	return GatesActivation(r) || RestartsOnLoss(r)
}

type DependNode struct {
	Ref      string
	Provides []string
	Requires []Required
}

func DependencyCycle(nodes []DependNode) []string {
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
