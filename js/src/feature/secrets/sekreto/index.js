// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (javascript/src/index.js)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// @voxgig/sekreto-js - one interface for secrets, wherever they live.

const sekreto = require('./Sekreto')

// THE CORE SURFACE: the chain, the four built-in provider kinds, and the
// means of adding a fifth.
//
// The built-ins are the kinds that read at most a local file - env,
// memory, dotenv, file. Everything that opens a socket, spawns a process
// or signs a request is a PLUGIN, is not reachable from this file, and
// is handed to `Sekreto` by the calling project:
//
//     const { Sekreto } = require('@voxgig/sekreto-js')
//     const { hashicorp } = require('@voxgig/sekreto-js/plugins/hashicorp')
//
//     const secrets = new Sekreto({
//       plugins: [hashicorp],
//       providers: [{ kind: 'env' }, { kind: 'hashicorp', addr, token }],
//     })
//
// or, for every kind at once, `allplugins` from
// '@voxgig/sekreto-js/plugins'. Re-exporting a plugin here would put AWS
// request signing in every build again, which is the thing the split
// removes. See docs/design/plugin-providers.md.
const { envprovider } = require('./provider/env')
const { memoryprovider } = require('./provider/memory')
const { dotenvprovider } = require('./provider/dotenv')
const { fileprovider } = require('./provider/file')
const { BUILTINS, KINDS } = require('./provider/builtin')

// How a provider kind becomes a plugin definition - the one call a
// custom kind needs.
const { ERROR_CODE, PROVIDER_EXPORT, providerplugin } = require('./provider/support')

// Pure validators, no platform dependency - kept on the core surface
// because callers validate an address before configuring a provider.
const { checkaddr, safeaddr } = require('./provider/addr')

module.exports = {
  ...sekreto,

  BUILTINS,
  ERROR_CODE,
  KINDS,
  PROVIDER_EXPORT,
  checkaddr,
  dotenvprovider,
  envprovider,
  fileprovider,
  memoryprovider,
  providerplugin,
  safeaddr,
}
