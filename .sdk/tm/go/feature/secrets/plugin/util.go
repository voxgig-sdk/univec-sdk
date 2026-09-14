// VENDORED: @voxgig/plugin 0.1.6 (go/plugin/util.go)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The handful of helpers the port needs that the canonical gets from
 * JavaScript for free: sorted map keys (Object.keys(x).sort()), a
 * JSON.stringify-equivalent marshal, and deep clone.
 *
 * `each(...) in sorted-key order` is a house rule across voxgig
 * because it makes output BYTE-STABLE. Go's map iteration is
 * deliberately randomized, so every traversal here goes through
 * sortedkeys — an unsorted `for k := range m` is a bug that passes its
 * own tests most of the time. */

package plugin

import (
	"bytes"
	"encoding/json"
	"sort"
)

func sortedkeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// marshal is json.Marshal WITHOUT HTML escaping, so a `<` in a value
// renders as itself and message parity holds against ports whose JSON
// writer never had an opinion about HTML.
func marshal(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); nil != err {
		return nil, err
	}
	return bytes.TrimRight(buf.Bytes(), "\n"), nil
}

// ismap is the canonical's `isMap`: a JSON object, and not a list.
func ismap(v any) bool {
	_, ok := v.(map[string]any)
	return ok
}

func aslist(v any) ([]any, bool) {
	l, ok := v.([]any)
	return l, ok
}

func clonevalue(v any) any {
	switch t := v.(type) {
	case map[string]any:
		out := map[string]any{}
		for k, e := range t {
			out[k] = clonevalue(e)
		}
		return out
	case []any:
		out := make([]any, len(t))
		for i, e := range t {
			out[i] = clonevalue(e)
		}
		return out
	default:
		return v
	}
}

// indexof is `Array.prototype.indexOf` for the string lists this port
// carries everywhere.
func indexof(l []string, s string) int {
	for i, e := range l {
		if e == s {
			return i
		}
	}
	return -1
}

func hasstring(l []string, s string) bool {
	return -1 != indexof(l, s)
}
