// VENDORED: @voxgig/plugin 0.1.6 (go/plugin/env.go)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
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
	Env      map[string]string `json:"env"`
	Refs     []string          `json:"refs,omitempty"`
	Reserved []string          `json:"reserved,omitempty"`
}

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

func parsevalue(v string) any {
	var out any
	if err := json.Unmarshal([]byte(v), &out); nil != err {
		return v
	}
	return out
}
