// VENDORED: @voxgig/plugin 0.1.6 (go/plugin/version.go)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package plugin

import (
	"regexp"
	"strconv"
	"strings"
)

type Range struct {
	Lo []int `json:"lo"`
	Hi []int `json:"hi"`
}

var versionRe = regexp.MustCompile(`^(\d+)(?:\.(\d+))?(?:\.(\d+))?$`)

const componentMax = 2147483647

func ParseRange(rng string) (Range, error) {
	bad := func() (Range, error) {
		return Range{}, Fail("plugin_bad_range", "invalid range: "+rng,
			map[string]any{"range": rng})
	}
	if 0 == len(rng) {
		return bad()
	}

	tilde := strings.HasPrefix(rng, "~")
	body := rng
	if tilde {
		body = rng[1:]
	}
	m := versionRe.FindStringSubmatch(body)
	if nil == m {
		return bad()
	}

	major, ok := component(m[1])
	if !ok {
		return bad()
	}
	minor, ok := component(m[2])
	if !ok {
		return bad()
	}
	patch, ok := component(m[3])
	if !ok {
		return bad()
	}

	lo := []int{major, minor, patch}
	hi := []int{major + 1, 0, 0}
	if tilde {
		hi = []int{major, minor + 1, 0}
	}
	return Range{Lo: lo, Hi: hi}, nil
}

func ParseVersion(version string) ([]int, error) {
	m := versionRe.FindStringSubmatch(version)
	if nil == m {
		return nil, Fail("plugin_bad_range", "invalid version: "+version,
			map[string]any{"version": version})
	}
	out := []int{}
	for _, g := range []string{m[1], m[2], m[3]} {
		n, ok := component(g)
		if !ok {
			return nil, Fail("plugin_bad_range",
				"version component out of range in "+version+": "+g,
				map[string]any{"version": version})
		}
		out = append(out, n)
	}
	return out, nil
}

// component parses one bounded component. An absent optional group is
// "", which is a missing minor or patch and therefore 0.
func component(s string) (int, bool) {
	if "" == s {
		return 0, true
	}
	n, err := strconv.Atoi(s)
	if nil != err || componentMax < n {
		return 0, false
	}
	return n, true
}

// Satisfies is the one satisfaction predicate: lo <= version < hi.
func Satisfies(version string, rng string) (bool, error) {
	v, err := ParseVersion(version)
	if nil != err {
		return false, err
	}
	r, err := ParseRange(rng)
	if nil != err {
		return false, err
	}
	return 0 <= Cmp(v, r.Lo) && 0 > Cmp(v, r.Hi), nil
}

// satisfiesq is Satisfies for the internal callers that treat an
// unparseable version or range as "does not satisfy" — Capability and
// Graph, both of which run over data the corpus has already admitted.
func satisfiesq(version string, rng string) bool {
	ok, err := Satisfies(version, rng)
	return nil == err && ok
}

func Cmp(a []int, b []int) int {
	for i := 0; i < 3; i++ {
		x, y := at(a, i), at(b, i)
		if x != y {
			if x < y {
				return -1
			}
			return 1
		}
	}
	return 0
}

func at(l []int, i int) int {
	if i < len(l) {
		return l[i]
	}
	return 0
}
