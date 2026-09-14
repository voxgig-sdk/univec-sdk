// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/Export.ts)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Exports (§11).
 *
 * An instance publishes values for other plugins and for the
 * application. Read with `host.exports('retry$fast/client')`.
 *
 * THE UNQUALIFIED ALIAS IS THE INTERESTING PART. `retry/client`
 * resolves to the UNTAGGED instance if one exists; if not, and exactly
 * one tagged instance exports that key, it resolves to that one; if two
 * do, it is `plugin_export_ambiguous` — deliberately diverging from
 * seneca's silent last-wins, because with multi-instance as a headline
 * feature an ambiguous alias is a defect waiting for production. */

import { fail } from './Types'
import { parseref, canonref } from './Ref'

export type Exported = { ref: string, key: string, value: any }

export function resolveexport(spec: string, exported: Exported[]): any {
  const cut = spec.indexOf('/')
  if (-1 === cut) {
    fail('plugin_export_ambiguous', 'export spec needs a key: ' + spec, { spec })
  }
  const head = spec.substring(0, cut)
  const key = spec.substring(cut + 1)

  // A fully qualified ref: exactly one answer or none.
  const exact = exported.filter((e) => e.ref === canonref(head) && e.key === key)
  if (0 < exact.length) return exact[0].value

  // An alias: the name, not a ref. Look at every instance of it.
  const byname = exported.filter((e) => parseref(e.ref).name === head && e.key === key)
  if (0 === byname.length) return undefined

  const untagged = byname.filter((e) => '' === parseref(e.ref).tag)
  if (0 < untagged.length) return untagged[0].value

  if (1 === byname.length) return byname[0].value

  const refs = byname.map((e) => e.ref).sort()
  fail('plugin_export_ambiguous',
    'alias ' + spec + ' matches ' + refs.length + ' instances: ' + refs.join(', '),
    { spec, refs })
}
