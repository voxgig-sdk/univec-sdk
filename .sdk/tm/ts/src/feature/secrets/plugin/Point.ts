// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/Point.ts)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

import { fail } from './Types'

export type Kind = 'hook' | 'chain' | 'provider'

export type Mode = 'emit' | 'parallel' | 'serial' | 'bail'

export type Spec = {
  kind?: Kind
  mode?: Mode
  /** `chain` only: the host owns the base, and a plugin cannot replace
   * it (§6.2). One that wants to SUBSTITUTE rather than wrap binds
   * innermost and simply does not call `next`. */
  base?: (...args: any[]) => any
  /** `provider` only: a second binding is an error rather than a
   * shadow. */
  exclusive?: boolean
  /** `provider` only: the host's fallback. */
  default?: any
  pin?: { [name: string]: 'outermost' | 'innermost' | 'first' | 'last' }
}

export type Bound = {
  ref: string
  point: string
  fn: any
  band: number
}

/** Fan-out. Return values are ignored except in `bail`. */
export function emit(bindings: Bound[], mode: Mode, arg: any): any {
  if ('bail' === mode) {
    for (const b of bindings) {
      const v = b.fn(arg)
      if (null != v) return v
    }
    return undefined
  }

  const errors: any[] = []
  for (const b of bindings) {
    try { b.fn(arg) }
    catch (err) {
      // `emit` raises synchronously; the collecting modes gather.
      if ('emit' === mode) throw err
      errors.push(err)
    }
  }
  return 'emit' === mode ? undefined : errors
}

export function compose(bindings: Bound[], base: (...args: any[]) => any): (...args: any[]) => any {
  let next = base
  for (let i = bindings.length - 1; 0 <= i; i--) {
    const fn = bindings[i].fn
    const inner = next
    next = (...args: any[]) => fn(inner, ...args)
  }
  return next
}

export function provider(bindings: Bound[], spec: Spec): { winner?: Bound, shadowed: string[] } {
  if (0 === bindings.length) return { shadowed: [] }

  if (spec.exclusive && 1 < bindings.length) {
    const refs = bindings.map((b) => b.ref).sort()
    fail('plugin_point_exclusive',
      'point is exclusive and has ' + bindings.length + ' bindings: ' + refs.join(', '),
      { refs })
  }

  const ranked = bindings.slice().sort((a, b) => {
    if (a.band !== b.band) return b.band - a.band
    return a.ref < b.ref ? -1 : a.ref > b.ref ? 1 : 0
  })

  return { winner: ranked[0], shadowed: ranked.slice(1).map((b) => b.ref) }
}
