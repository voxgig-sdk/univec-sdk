// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (javascript/src/provider/support.js)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */

// What a provider is, what its declarative form looks like, and how a
// provider kind becomes a voxgig/plugin definition.
//
// A provider answers one question: "do you have this secret?" It returns
// the value, or undefined to mean "ask the next one". Nothing else about
// a provider is visible to the caller - which is the point: an app reads
// `api.token` and never learns whether it came from the environment, a
// .env file, HashiCorp Vault, AWS, GCP, Azure or a boru vault.
//
// Two failure shapes, and they are never interchangeable. A store that
// does not hold the secret is a MISS (undefined) - the chain carries on.
// A store that could not answer - bad credentials, unreachable host,
// missing configuration - is an ERROR: falling through there would
// quietly reach for a weaker store.
//
// A port of typescript/src/provider/support.ts, which is canonical.

const { PluginError } = require('../../plugin')

// Sekreto.js is required at the TOP here, and requires nothing under
// this directory at the top of itself - it reaches builtin.js through a
// function. That is what keeps the pair acyclic in CommonJS, where a
// module that replaces `module.exports` at the end of its body hands a
// stale empty object to anything that required it half-built.
const {
  ERROR_CODE,
  PROVIDER_EXPORT,
  SekretoError,
  awsparam,
  checkname,
  envkey,
  flatname,
  parsedotenv,
  vaultref,
} = require('../Sekreto')

// NODE BUILTINS, LOADED ON FIRST USE.
//
// `fs` and `path` are what the two built-in file-reading providers need,
// and they are loaded when a lookup runs rather than when sekreto is
// required: a caller who only ever configures `memory` or `env` never
// evaluates them, and a runtime that lacks them fails at the point of
// use rather than at import. The platform-dependent providers proper -
// everything that opens a socket or spawns a process - are not in the
// core at all; they are plugins (docs/design/plugin-providers.md).
//
// A plain require(), not `await import()`: dotenvprovider and
// fileprovider have SYNCHRONOUS lookups, and making them async to
// accommodate a dynamic import would change observable behaviour for
// anyone calling a provider directly.
const nodemods = {}

function nodemod(name) {
  let mod = nodemods[name]

  if (undefined === mod) {
    try {
      mod = nodemods[name] = require(name)
    } catch (err) {
      throw new SekretoError(
        'sekreto: this provider needs ' +
          name +
          ', which this runtime does not provide: ' +
          err.message,
      )
    }
  }

  return mod
}

// --- providers as voxgig/plugin definitions --------------------------

// `PROVIDER_EXPORT` and `ERROR_CODE` are re-exported from Sekreto.js
// rather than declared here, where canonical declares them: both ends of
// the plugin boundary need them, and this module sits on the far side of
// the one deferred require that keeps the pair acyclic in CommonJS.
// Every consumer still reads them from here, as canonical's do.

/** A provider kind, as a voxgig/plugin definition.
 *
 * This is the whole bridge between the two libraries. The definition's
 * `name` is the `kind` a provider spec names; its `define` reads the
 * spec as `inst.options`, builds the provider with `make`, and exports
 * it. Nothing runs at `activate`: a provider opens nothing until its
 * first lookup, so there is nothing to capture - a provider that does
 * hold a resource acquires it there and lets the instance scope unwind
 * it.
 *
 * Every built-in and every plugin is made this way, so a custom
 * provider kind is one call:
 *
 *     providerplugin('mystore', (spec) => mystoreprovider(spec.addr))
 */
function providerplugin(kind, make) {
  return {
    name: kind,
    define: (inst) => {
      let provider
      try {
        provider = make(inst.options)
      } catch (err) {
        if (err instanceof SekretoError) {
          throw new PluginError(ERROR_CODE, err.message, { ref: inst.ref, cause: err.message })
        }
        throw err
      }
      inst.export(PROVIDER_EXPORT, provider)
    },
  }
}

/** Decode standard base64, or undefined when the text is not base64.
 *
 * `Buffer.from(text, 'base64')` is lenient: it skips anything outside the
 * alphabet and hands back whatever it managed, so a corrupted payload
 * became a plausible-looking string of bytes that the caller then returned
 * AS THE SECRET. The alphabet is checked first, so a store that answered
 * incoherently can be told apart from one that answered.
 *
 * A store that could not answer coherently is an ERROR, never a miss - the
 * same rule this library already applies to a 200 whose body is not JSON. */
function unbase64(text) {
  const trimmed = text.replace(/\s+/g, '')

  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(trimmed) || 0 !== trimmed.length % 4) {
    return undefined
  }

  return Buffer.from(trimmed, 'base64').toString('utf8')
}

module.exports = {
  ERROR_CODE,
  PROVIDER_EXPORT,
  SekretoError,
  awsparam,
  checkname,
  envkey,
  flatname,
  nodemod,
  parsedotenv,
  providerplugin,
  unbase64,
  vaultref,
}
