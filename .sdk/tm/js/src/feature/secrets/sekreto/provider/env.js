// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (javascript/src/provider/env.js)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */

const { envkey } = require('./support')

/** Environment variables: `api.token` from `API_TOKEN`. */
function envprovider(prefix, source) {
  const env = source || process.env

  return {
    lookup: (name) => {
      const value = env[envkey(name, prefix)]
      return undefined === value || null === value ? undefined : String(value)
    },
    describe: () => 'env' + (prefix ? ':' + prefix : ''),
  }
}

module.exports = { envprovider }
