// VENDORED: @voxgig/plugin 0.1.6 (go/plugin/env.go)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Environment overrides (§9.5) — level 7 of the ladder.
 *
 * One prefix, so nothing drifts: `VOXGIG_PLUGIN_*`.
 *
 *   VOXGIG_PLUGIN_PROFILE            the profile name
 *   VOXGIG_PLUGIN_<REF>_<PATH>       one option
 *   VOXGIG_PLUGIN_ACTIVE/INACTIVE    comma-separated refs, INACTIVE wins
 *
 * THE ENCODING IS LOSSY, AND THIS SAYS SO RATHER THAN PRETENDING
 * OTHERWISE. Ref and path are upper-snake with `$` -> `__` and `.` ->
 * `_`. But `_` is legal in a name and in a tag, and the mapping folds
 * case, so `retry$fast` and `retry__fast` both encode to `RETRY__FAST`,
 * as do `Retry$fast` and `retry$Fast`.
 *
 * Rather than restrict a grammar the rest of the stack already uses, the
 * host DETECTS THE COLLISION: it encodes every ref it holds, and a key
 * two refs claim is `plugin_env_ambiguous`, naming both. The affected
 * pair stays configurable by document and by API, just not by
 * environment — which is the honest trade.
 *
 * Pure: a function over a string map and a ref set. The corpus tests it
 * without touching a real environment. */

package plugin

import (
	"encoding/json"
	"sort"
	"strings"
)

const envPrefix = "VOXGIG_PLUGIN_"

type EnvResult struct {
	Profile  string         `json:"profile,omitempty"`
	Options  map[string]any `json:"options"`
	Active   []string       `json:"active"`
	Inactive []string       `json:"inactive"`
}

type EnvInput struct {
	Env map[string]string `json:"env"`
	// Refs is every ref the host holds. Needed because the encoding is
	// lossy: without the set there is no way to know where the ref ends
	// and the path begins in `RETRY__FAST_MIN_DELAY`.
	Refs     []string `json:"refs,omitempty"`
	Reserved []string `json:"reserved,omitempty"`
}

// EncodeRef: `retry$fast` -> `RETRY__FAST`.
func EncodeRef(ref string) string {
	s := strings.ReplaceAll(ref, "$", "__")
	s = strings.ReplaceAll(s, ".", "_")
	return strings.ToUpper(s)
}

func ApplyEnv(input EnvInput) (EnvResult, error) {
	out := EnvResult{Options: map[string]any{}, Active: []string{}, Inactive: []string{}}

	refs := []string{}
	for _, r := range input.Refs {
		c, err := CanonRef(r)
		if nil != err {
			return out, err
		}
		refs = append(refs, c)
	}

	// Encode every ref the host holds, and refuse a key that two of them
	// claim. Done up front so the collision is reported even when no
	// environment variable exercises it — a latent ambiguity is still an
	// ambiguity, and finding it at deploy time is the failure this
	// exists to prevent.
	byencoded := map[string][]string{}
	for _, r := range refs {
		e := EncodeRef(r)
		byencoded[e] = append(byencoded[e], r)
	}
	for _, e := range sortedkeys(byencoded) {
		if 1 < len(byencoded[e]) {
			pair := append([]string{}, byencoded[e]...)
			sort.Strings(pair)
			return out, Fail("plugin_env_ambiguous",
				"refs collide in the environment encoding as "+e+": "+strings.Join(pair, ", "),
				map[string]any{"encoded": e, "refs": pair})
		}
	}

	// Longest encoded ref first, so `retry$fast` wins over `retry` on
	// `RETRY__FAST_MIN`. Shortest-first would read the tag as a path.
	// Equal lengths break bytewise: the canonical leans on JavaScript's
	// stable sort over insertion order, which a Go map cannot reproduce
	// and which no entry can distinguish anyway.
	encoded := sortedkeys(byencoded)
	sort.SliceStable(encoded, func(i, j int) bool {
		return len(encoded[i]) > len(encoded[j])
	})

	for _, key := range sortedkeys(input.Env) {
		if !strings.HasPrefix(key, envPrefix) {
			continue
		}
		rest := key[len(envPrefix):]

		if "PROFILE" == rest {
			out.Profile = input.Env[key]
			continue
		}

		if "ACTIVE" == rest || "INACTIVE" == rest {
			for _, r := range splitlist(input.Env[key]) {
				c, err := CanonRef(r)
				if nil != err {
					return out, err
				}
				// The reservation covers EVERY input layer (§9.1).
				// VOXGIG_PLUGIN_INACTIVE=station is easier to set than
				// editing a config file, and INACTIVE has the final
				// word — so guarding documents alone would leave the one
				// lever this mechanism exists to deny wide open.
				if err := checkreservedref(c, input.Reserved); nil != err {
					return out, err
				}
				if "ACTIVE" == rest {
					out.Active = append(out.Active, c)
				} else {
					out.Inactive = append(out.Inactive, c)
				}
			}
			continue
		}

		enc := ""
		for _, e := range encoded {
			if rest == e || strings.HasPrefix(rest, e+"_") {
				enc = e
				break
			}
		}
		if "" == enc {
			continue // not for any ref this host holds
		}
		ref := byencoded[enc][0]
		if err := checkreservedref(ref, input.Reserved); nil != err {
			return out, err
		}

		if rest == enc {
			continue // a ref with no path sets nothing
		}
		path := strings.Split(strings.ToLower(rest[len(enc)+1:]), "_")

		node, ok := out.Options[ref].(map[string]any)
		if !ok {
			node = map[string]any{}
			out.Options[ref] = node
		}
		for i := 0; i < len(path)-1; i++ {
			child, ok := node[path[i]].(map[string]any)
			if !ok {
				child = map[string]any{}
				node[path[i]] = child
			}
			node = child
		}
		node[path[len(path)-1]] = parsevalue(input.Env[key])
	}

	return out, nil
}

func splitlist(v string) []string {
	out := []string{}
	for _, s := range strings.Split(v, ",") {
		if t := strings.TrimSpace(s); 0 < len(t) {
			out = append(out, t)
		}
	}
	return out
}

// parsevalue: values parse as JSON, FALLING BACK TO STRING — so `8080`
// is a number, `true` is a boolean, `{"a":1}` is a map, and `hello` is
// the string it looks like rather than a parse error.
func parsevalue(v string) any {
	var out any
	if err := json.Unmarshal([]byte(v), &out); nil != err {
		return v
	}
	return out
}
