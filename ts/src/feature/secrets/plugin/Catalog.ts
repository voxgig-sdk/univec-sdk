// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/Catalog.ts)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

import { fail } from './Types'
import { checkname } from './Ref'
import { checkshape } from './Config'

export type Definition = {
  name: string
  shape?: any
  define?: (inst: any) => void
  activate?: (inst: any) => void
  deactivate?: (inst: any) => void
  close?: (inst: any) => void
  reconfigure?: (inst: any, options: any, previous: any) => void
}

export type Catalog = {
  add: (def: Definition) => void
  get: (name: string) => Definition | undefined
  has: (name: string) => boolean
  names: () => string[]
}

export function makecatalog(defs?: Definition[]): Catalog {
  const map: { [name: string]: Definition } = {}

  const add = (def: Definition): void => {
    if (!def || !checkname(def.name)) {
      fail('plugin_definition_name', 'invalid definition name: ' + (def && def.name))
    }
    // Validate the shape HERE. Deferring it to resolution time means a
    // malformed shape surfaces at a different moment in every host that
    // loads it, which is the divergence the stated domain exists to
    // prevent.
    if (def.shape) checkshape(def.shape)
    map[def.name] = def
  }

  for (const d of defs || []) add(d)

  return {
    add,
    get: (name: string) => map[name],
    has: (name: string) => undefined !== map[name],
    names: () => Object.keys(map).sort(),
  }
}
