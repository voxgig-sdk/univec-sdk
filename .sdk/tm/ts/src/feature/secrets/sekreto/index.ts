// VENDORED: @voxgig/sekreto 0.2.0 (typescript/src/index.ts)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// @voxgig/sekreto - one interface for secrets, wherever they live.

export {
  Sekreto,
  SekretoError,
  awsparam,
  envkey,
  flatname,
  parsedotenv,
  redact,
  sekreto,
  validname,
  vaultref,
} from './Sekreto'

export type { Name, SekretoOptions } from './Sekreto'

// THE CORE SURFACE: the chain, the four built-in provider kinds, and the
// means of adding a fifth.
//
// The built-ins are the kinds that read at most a local file - env,
// memory, dotenv, file. Everything that opens a socket, spawns a process
// or signs a request is a PLUGIN, is not reachable from this file, and
// is handed to `Sekreto` by the calling project:
//
//     import { Sekreto } from '@voxgig/sekreto'
//     import { hashicorp } from '@voxgig/sekreto/plugins/hashicorp'
//
//     const secrets = new Sekreto({
//       plugins: [hashicorp],
//       providers: [{ kind: 'env' }, { kind: 'hashicorp', addr, token }],
//     })
//
// or, for every kind at once, `allplugins` from '@voxgig/sekreto/plugins'.
// Re-exporting a plugin here would put AWS request signing in every
// build again, which is the thing the split removes. See
// docs/design/plugin-providers.md.
export { envprovider } from './provider/env'
export { memoryprovider } from './provider/memory'
export { dotenvprovider } from './provider/dotenv'
export { fileprovider } from './provider/file'
export { BUILTINS, KINDS } from './provider/builtin'

// How a provider kind becomes a plugin definition - the one call a
// custom kind needs.
export { providerplugin, PROVIDER_EXPORT, ERROR_CODE } from './provider/support'

// A pure validator, no platform dependency - kept on the core surface
// because callers validate an address before configuring a provider.
export { checkaddr, safeaddr } from './provider/addr'

export type { Provider, ProviderSpec } from './provider/support'
export type { Definition } from '../plugin'
