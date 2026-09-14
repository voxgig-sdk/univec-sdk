// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/Resolve.ts)
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
 * The corpus `resolve` section arrives with P2. */

export type Source =
  | { kind: 'module', prefix?: string[] }
  | { kind: 'path', dir: string }

export function resolvecandidates(name: string, sources?: Source[]): string[] {
  const out: string[] = []

  // A SCOPED NAME RESOLVES VERBATIM ONLY (§10.2). `@acme/thing` is
  // already a package id; prefixing it produces
  // `@voxgig/plugin-@acme/thing`, which is not a thing that can exist.
  if (name.startsWith('@')) return [name]

  const list = sources && 0 < sources.length ? sources : DEFAULT_SOURCES

  for (const src of list) {
    if ('module' === src.kind) {
      const prefixes = src.prefix && 0 < src.prefix.length ? src.prefix : ['']
      for (const p of prefixes) {
        const id = p + name
        if (-1 === out.indexOf(id)) out.push(id)
      }
    }
    else if ('path' === src.kind) {
      const id = src.dir.replace(/\/+$/, '') + '/' + name
      if (-1 === out.indexOf(id)) out.push(id)
    }
  }

  return out
}

const DEFAULT_SOURCES: Source[] = [
  { kind: 'module', prefix: ['@voxgig/plugin-', 'voxgig-plugin-', 'plugin-', ''] },
]

/** A MODULE PATH IS NOT A NAME (§10.2). The ref grammar starts a name
 * with a letter or `@`, so `./local/thing` is not a ref and never
 * reaches candidate generation — seneca allows a path where a plugin
 * name goes, and this design deliberately does not, because a ref is an
 * ADDRESS WITHIN A HOST and a path is a LOCATION ON A DISK.
 *
 * Loading from an explicit location is a separate field that bypasses
 * candidate generation entirely: `from` is passed to the resolver
 * verbatim, and a resolver that cannot honour a location raises
 * plugin_resolve_failed. */
export function resolvefrom(from: string): string[] {
  return [from]
}
