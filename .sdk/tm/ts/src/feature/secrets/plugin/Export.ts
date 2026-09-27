// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/Export.ts)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

import { fail } from './Types'
import { parseref, canonref } from './Ref'

export type Exported = { ref: string, key: string, value: any }

export function resolveexport(spec: string, exported: Exported[]): any {
  const cut = spec.lastIndexOf('/')
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
