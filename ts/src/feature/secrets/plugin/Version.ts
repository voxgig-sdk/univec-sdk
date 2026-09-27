// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/Version.ts)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

import { fail } from './Types'

export type Range = { lo: number[], hi: number[] }

const VERSION_RE = /^(\d+)(?:\.(\d+))?(?:\.(\d+))?$/

const COMPONENT_MAX = 2147483647

export function parserange(range: string): Range {
  if ('string' !== typeof range || 0 === range.length) {
    fail('plugin_bad_range', 'invalid range: ' + range, { range })
  }

  const tilde = range.startsWith('~')
  const body = tilde ? range.substring(1) : range
  const m = VERSION_RE.exec(body)
  if (!m) fail('plugin_bad_range', 'invalid range: ' + range, { range })

  const major = component(m[1], range, 'range')
  const minor = undefined === m[2] ? 0 : component(m[2], range, 'range')
  const patch = undefined === m[3] ? 0 : component(m[3], range, 'range')

  const lo = [major, minor, patch]
  const hi = tilde ? [major, minor + 1, 0] : [major + 1, 0, 0]
  return { lo, hi }
}

export function parseversion(version: string): number[] {
  if ('string' !== typeof version) {
    fail('plugin_bad_range', 'invalid version: ' + version, { version })
  }
  const m = VERSION_RE.exec(version)
  if (!m) fail('plugin_bad_range', 'invalid version: ' + version, { version })
  return [
    component(m[1], version, 'version'),
    undefined === m[2] ? 0 : component(m[2], version, 'version'),
    undefined === m[3] ? 0 : component(m[3], version, 'version'),
  ]
}

function component(digits: string, whole: string, field: string): number {
  const n = Number(digits)
  if (!Number.isInteger(n) || COMPONENT_MAX < n) {
    fail('plugin_bad_range',
      'version component out of range in ' + whole + ': ' + digits,
      { [field]: whole })
  }
  return n
}

/** The one satisfaction predicate: lo <= version < hi. */
export function satisfies(version: string, range: string): boolean {
  const v = parseversion(version)
  const r = parserange(range)
  return 0 <= cmp(v, r.lo) && 0 > cmp(v, r.hi)
}

export function cmp(a: number[], b: number[]): number {
  for (let i = 0; i < 3; i++) {
    if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1
  }
  return 0
}
