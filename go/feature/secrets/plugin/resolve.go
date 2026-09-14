// VENDORED: @voxgig/plugin 0.1.6 (go/plugin/resolve.go)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Dynamic resolution (§10.2) — name to candidate module ids.
 *
 * PURE. It returns the ids a host WOULD try, in order; it does not load
 * anything. That separation is what lets the corpus pin resolution in
 * every language including those with no dynamic loading at all, and it
 * is why §15.4 puts real module loading in per-port integration tests
 * rather than here.
 *
 * GO IS TIER S (§10.3): static-only, registration through `init()` or
 * an explicit list handed to MakeHost. That changes nothing here —
 * candidate generation is what the corpus pins, and a port with no
 * dynamic loading at all still answers it identically. */

package plugin

import "strings"

type Source struct {
	Kind   string   `json:"kind"`
	Prefix []string `json:"prefix,omitempty"`
	Dir    string   `json:"dir,omitempty"`
}

func ResolveCandidates(name string, sources []Source) []string {
	out := []string{}

	// A SCOPED NAME RESOLVES VERBATIM ONLY (§10.2). `@acme/thing` is
	// already a package id; prefixing it produces
	// `@voxgig/plugin-@acme/thing`, which is not a thing that can exist.
	if strings.HasPrefix(name, "@") {
		return []string{name}
	}

	list := sources
	if 0 == len(list) {
		list = defaultSources
	}

	for _, src := range list {
		if "module" == src.Kind {
			prefixes := src.Prefix
			if 0 == len(prefixes) {
				prefixes = []string{""}
			}
			for _, p := range prefixes {
				if id := p + name; !hasstring(out, id) {
					out = append(out, id)
				}
			}
		} else if "path" == src.Kind {
			if id := strings.TrimRight(src.Dir, "/") + "/" + name; !hasstring(out, id) {
				out = append(out, id)
			}
		}
	}

	return out
}

var defaultSources = []Source{
	{Kind: "module", Prefix: []string{"@voxgig/plugin-", "voxgig-plugin-", "plugin-", ""}},
}

// ResolveFrom: A MODULE PATH IS NOT A NAME (§10.2). The ref grammar
// starts a name with a letter or `@`, so `./local/thing` is not a ref
// and never reaches candidate generation — seneca allows a path where a
// plugin name goes, and this design deliberately does not, because a ref
// is an ADDRESS WITHIN A HOST and a path is a LOCATION ON A DISK.
//
// Loading from an explicit location is a separate field that bypasses
// candidate generation entirely: `from` is passed to the resolver
// verbatim, and a resolver that cannot honour a location raises
// plugin_resolve_failed.
func ResolveFrom(from string) []string {
	return []string{from}
}
