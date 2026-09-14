// VENDORED: @voxgig/sekreto 0.2.0 (typescript/plugins/httpjson.ts)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */

import { SekretoError } from '../provider/support'

/** How long any single vault round-trip may take before it is treated as
 * unreachable. Ports carry the same bound. */
const HTTP_TIMEOUT_MS = 10000

/** How much of a response body will be read before the store is treated as
 * having answered incoherently. Ports carry the same bound.
 *
 * Far above anything real. The largest legitimate payload this library
 * fetches is Doppler's whole-config download, measured in kilobytes; a
 * megabyte would do. Eight is chosen so that no honest store can meet it
 * and the check never has to be reasoned about again.
 *
 * A bound is needed because the timeout is not one. Ten seconds on a
 * loopback or datacentre link is gigabytes, and the body is accumulated
 * in memory before it is parsed — measured at 3.2 GB in one port before
 * this. Worse where a client advertises gzip and decompresses
 * transparently, since a few hundred kilobytes of zeros expands to
 * gigabytes in the client's heap. This is a secrets chain running on an
 * application's startup path, so the failure is the application never
 * starting. */
const HTTP_MAXBODY = 8 * 1024 * 1024

/** One JSON round-trip. Network failure is always an error - an
 * unreachable store is a store that could not answer.
 *
 * Shared by every plugin that speaks HTTP, and by nothing in the core:
 * a chain of built-ins never reaches this file. */
export async function fetchjson(
  method: string,
  url: string,
  headers: Record<string, string>,
  body?: string,
): Promise<{ status: number; body: any }> {
  let res: Response
  try {
    res = await fetch(url, {
      method,
      headers,
      body,
      // A vault API never legitimately redirects, and a followed redirect
      // carries X-Vault-Token to the redirect's host (and can downgrade
      // https to http), which checkaddr - it only validates the configured
      // address - cannot see. Refuse to follow one.
      redirect: 'error',
      // Bound the wait so an accepted-but-silent endpoint cannot hang the
      // caller (and the app's startup) forever.
      signal: AbortSignal.timeout(HTTP_TIMEOUT_MS),
    })
  } catch (err: any) {
    throw new SekretoError('sekreto: cannot reach ' + url.split('?')[0] + ': ' + err.message)
  }

  // Read in chunks against HTTP_MAXBODY rather than `res.json()`, which
  // buffers whatever arrives. Over the bound the request is aborted and
  // the store has failed: an endless body is a store that could not
  // answer, and returning a miss there would fall through to a weaker
  // store on an attacker's cue.
  let text = ''
  try {
    const decoder = new TextDecoder()
    let size = 0

    for await (const chunk of res.body ?? []) {
      size += chunk.length
      if (HTTP_MAXBODY < size) {
        throw new SekretoError('sekreto: oversized response from ' + url.split('?')[0])
      }
      text += decoder.decode(chunk, { stream: true })
    }
    text += decoder.decode()
  } catch (err: any) {
    if (err instanceof SekretoError) {
      throw err
    }
    throw new SekretoError('sekreto: cannot reach ' + url.split('?')[0] + ': ' + err.message)
  }

  let parsed: any = undefined
  try {
    parsed = JSON.parse(text)
  } catch (err: any) {
    // A success status promised JSON; a body that does not parse means
    // the store could not answer coherently, and treating it as a miss
    // would fall through to a weaker store. Error statuses may carry
    // any body - they are decided on status alone.
    if (200 === res.status) {
      throw new SekretoError('sekreto: malformed response from ' + url.split('?')[0])
    }
  }

  return { status: res.status, body: parsed }
}
