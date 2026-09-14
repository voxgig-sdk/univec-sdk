// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/Version.ts)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Versions and ranges (§11.2).
 *
 * TWO FIELDS AND ONE PREDICATE. A capability declares `version`, a
 * concrete version. A requirement declares `range`. A requirement is
 * satisfied when the names match, the `match` passes, and:
 *
 *   the provider's `version` falls inside the requirement's `range`.
 *
 * That is the whole rule. There is no third field and no second
 * comparison — an earlier draft added a provider-side `compat` range,
 * which left three values and no statement of how they combine, and
 * three defensible readings of one declaration is worse than the
 * ambiguity it was introduced to fix. */

import { fail } from './Types'

export type Range = { lo: number[], hi: number[] }

const VERSION_RE = /^(\d+)(?:\.(\d+))?(?:\.(\d+))?$/

/** A COMPONENT IS BOUNDED, like a ref is (§4's 1024).
 *
 * The grammar admits an unbounded digit sequence, and every language
 * then disagrees about what happens past its integer range: JavaScript
 * silently loses precision, Go's `Atoi` errors (and a port ignoring that
 * gets 0), C overflows, Python is exact. `satisfies("0",
 * "9223372036854775808")` was false in the canonical and true in go —
 * from the same corpus.
 *
 * 2^31-1 because every port has a signed 32-bit integer, and no real
 * version has ever needed more. Stated rather than left to arithmetic
 * nobody agrees on. Found by review of the go port. */
const COMPONENT_MAX = 2147483647

/** Two forms and no more (§11.2):
 *
 *   '2.1'    >= 2.1.0 and < 3.0.0
 *   '~2.1'   >= 2.1.0 and < 2.2.0
 */
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

/** One component, bounded. `plugin_bad_range` either way — the same code
 * the rest of the grammar's failures use, because "this is not a version
 * I can compare" is one fact however it went wrong. */
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
