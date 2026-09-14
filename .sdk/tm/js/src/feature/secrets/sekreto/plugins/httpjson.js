// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (javascript/plugins/httpjson.js)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */

// The shared HTTP-JSON round-trip, used by every plugin that speaks
// HTTP and by nothing in the core: a chain of built-ins never reaches
// this file, which is why it lives under plugins/ rather than beside
// them (docs/design/plugin-providers.md).
//
// A port of typescript/plugins/httpjson.ts, which is canonical.

const { SekretoError } = require('../provider/support')

/** How long any single vault round-trip may take before it is treated as
 * unreachable. Ports carry the same bound. */
const HTTP_TIMEOUT_MS = 10000

/** How much of a response body will be read before the store is treated as
 * having answered incoherently. Ports carry the same bound.
 *
 * Far above anything real - the largest legitimate payload this library
 * fetches is Doppler's whole-config download, measured in kilobytes. A bound
 * is needed because the TIMEOUT is not one: ten seconds on a loopback or
 * datacentre link is gigabytes, and the body is accumulated in memory before
 * it is parsed. This runs on an application's startup path, so the failure is
 * the application never starting.
 */
const HTTP_MAXBODY = 8 * 1024 * 1024

/** One JSON round-trip. Network failure is always an error - an
 * unreachable store is a store that could not answer. */
async function fetchjson(method, url, headers, body) {
  let res
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
  } catch (err) {
    throw new SekretoError('sekreto: cannot reach ' + url.split('?')[0] + ': ' + err.message)
  }

  // Read in chunks against HTTP_MAXBODY rather than `res.json()`, which
  // buffers whatever arrives. Over the bound the store has failed: an
  // endless body is a store that could not answer, and returning a miss
  // there would fall through to a weaker store on an attacker's cue.
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
  } catch (err) {
    if (err instanceof SekretoError) {
      throw err
    }
    throw new SekretoError('sekreto: cannot reach ' + url.split('?')[0] + ': ' + err.message)
  }

  let parsed = undefined
  try {
    parsed = JSON.parse(text)
  } catch (_err) {
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

module.exports = { fetchjson }
