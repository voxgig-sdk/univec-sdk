// VENDORED: @voxgig/sekreto 0.2.0 (typescript/src/provider/addr.ts)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */

import { SekretoError } from './support'

export function safeaddr(addr: string): string {
  const mark = addr.indexOf('://')
  if (-1 === mark) {
    return addr
  }

  const rest = addr.slice(mark + 3)
  const end = rest.search(/[/?#]/)
  const authority = -1 === end ? rest : rest.slice(0, end)

  const at = authority.lastIndexOf('@')
  if (-1 === at) {
    return addr
  }

  return addr.slice(0, mark + 3) + '[redacted]' + addr.slice(mark + 3 + at)
}

export function checkaddr(addr: string): void {
  const scheme = addr.startsWith('https://')
    ? 'https://'
    : addr.startsWith('http://')
      ? 'http://'
      : ''

  if ('' === scheme) {
    throw new SekretoError('sekreto: not an http(s) address: ' + safeaddr(addr))
  }

  const rest = addr.slice(scheme.length)
  const end = rest.search(/[/?#]/)
  const authority = -1 === end ? rest : rest.slice(0, end)

  if (authority.includes('@')) {
    throw new SekretoError(
      'sekreto: refusing an address with embedded credentials: ' + safeaddr(addr),
    )
  }

  if (authority.startsWith('[') && !authority.includes(']')) {
    throw new SekretoError('sekreto: not a valid http(s) address: ' + safeaddr(addr))
  }

  if ('https://' === scheme) {
    return
  }

  // A bracketed IPv6 literal keeps its brackets. Splitting the authority
  // on the first colon yields '[', so `http://[::1]:8200` could never
  // match — which made the '[::1]' entry below unreachable, and refused a
  // legitimate local vault.
  const host = (
    authority.startsWith('[')
      ? authority.slice(0, authority.indexOf(']') + 1)
      : authority.split(':')[0]
  ).toLowerCase()

  if ('localhost' === host || '127.0.0.1' === host || '::1' === host || '[::1]' === host) {
    return
  }

  throw new SekretoError(
    'sekreto: refusing to send a token in plaintext to ' + safeaddr(addr) + ' (use https)',
  )
}

/** How long any single vault round-trip may take before it is treated as
 * unreachable. Ports carry the same bound. */

/** One JSON round-trip. Network failure is always an error - an
 * unreachable store is a store that could not answer. */
