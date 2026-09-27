// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/Ref.ts)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

import { Ref, fail } from './Types'

/** §4: `^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$`, max 1024. */
const NAME_RE = /^[a-zA-Z@][a-zA-Z0-9.~_\-\/]*$/
const TAG_RE = /^[a-zA-Z0-9.~_-]+$/

const MAX = 1024

export function checkname(name: string): boolean {
  if ('string' !== typeof name) return false
  if (0 === name.length || MAX < name.length) return false
  return NAME_RE.test(name)
}

export function checktag(tag: string): boolean {
  if ('string' !== typeof tag) return false
  // The empty tag is an ordinary tag (§4 rule 2). The single-instance
  // case writes no tag and never learns tags exist.
  if (0 === tag.length) return true
  if (MAX < tag.length) return false
  return TAG_RE.test(tag)
}

export function parseref(str: string): Ref {
  if ('string' !== typeof str) {
    fail('plugin_bad_name', 'ref must be a string')
  }

  const cut = str.indexOf('$')
  const name = -1 === cut ? str : str.substring(0, cut)
  const tag = -1 === cut ? '' : str.substring(cut + 1)

  if (!checkname(name)) {
    fail('plugin_bad_name', 'invalid plugin name: ' + name, { name })
  }
  if (!checktag(tag)) {
    fail('plugin_bad_tag', 'invalid plugin tag: ' + tag, { name, tag })
  }

  return { name, tag }
}

export function formatref(name: string, tag?: string): string {
  const t = null == tag ? '' : tag
  if (!checkname(name)) {
    fail('plugin_bad_name', 'invalid plugin name: ' + name, { name })
  }
  if (!checktag(t)) {
    fail('plugin_bad_tag', 'invalid plugin tag: ' + t, { name, tag: t })
  }
  return '' === t ? name : name + '$' + t
}

/** The canonical spelling of a ref. §4 rule 5: ports must canonicalize
 * before comparison. */
export function canonref(str: string): string {
  const r = parseref(str)
  return formatref(r.name, r.tag)
}

export function tryref(str: string): string | undefined {
  if ('string' !== typeof str) return undefined
  const cut = str.indexOf('$')
  const name = -1 === cut ? str : str.substring(0, cut)
  const tag = -1 === cut ? '' : str.substring(cut + 1)
  if (!checkname(name) || !checktag(tag)) return undefined
  return '' === tag ? name : name + '$' + tag
}
