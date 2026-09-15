// VENDORED: @voxgig/plugin 0.1.6 (go/plugin/version.go)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Versions and ranges (§11.2).
 *
 * TWO FIELDS AND ONE PREDICATE. A capability declares `version`, a
 * concrete version. A requirement declares `range`. A requirement is
 * satisfied when the names match, the `match` passes, and:
 *
 *   the provider's `version` falls inside the requirement's `range`.
 *
 * That is the whole rule. There is no third field and no second
 * comparison — an earlier draft added a provider-side `compat` range,
 * which left three values and no statement of how they combine, and
 * three defensible readings of one declaration is worse than the
 * ambiguity it was introduced to fix. */

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

// componentMax bounds a version component, like §4's 1024 bounds a ref.
//
// The grammar admits an unbounded digit sequence and every language then
// disagrees past its integer range: JavaScript silently loses precision,
// Go's Atoi errors (and this port was ignoring that, yielding 0), C
// overflows. `Satisfies("0", "9223372036854775808")` was false in the
// canonical and TRUE here, from the same corpus.
//
// 2^31-1, because every port has a signed 32-bit integer.
const componentMax = 2147483647

// ParseRange accepts two forms and no more (§11.2):
//
//	'2.1'    >= 2.1.0 and < 3.0.0
//	'~2.1'   >= 2.1.0 and < 2.2.0
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


