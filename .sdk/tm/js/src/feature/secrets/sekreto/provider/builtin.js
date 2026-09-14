// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (javascript/src/provider/builtin.js)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */

// THE BUILT-IN PROVIDER KINDS - the same four in every port.
//
// What makes a kind built in is that it needs nothing of the platform
// beyond reading a local file: no socket, no TLS, no crypto, no child
// process. These four are the floor every chain stands on, and a chain
// that reads secrets from options, the environment, a plaintext `.env`
// and a mounted secret directory works with no plugin loaded at all.
// Everything else - the vault clients, the cloud stores, the CLIs - is a
// plugin, and lives under `plugins/` (docs/design/plugin-providers.md).

const { providerplugin } = require('./support')
const { envprovider } = require('./env')
const { memoryprovider } = require('./memory')
const { dotenvprovider } = require('./dotenv')
const { fileprovider } = require('./file')

const BUILTINS = [
  providerplugin('env', (spec) => envprovider(spec.prefix)),
  providerplugin('memory', (spec) => memoryprovider(spec.values || {}, spec.prefix)),
  providerplugin('dotenv', (spec) => dotenvprovider(spec.file || '.env', spec.prefix)),
  providerplugin('file', (spec) => fileprovider(spec.dir || '', spec.prefix)),
]

/** Every kind this library ships, built in or as a plugin, so that an
 * unknown kind can be told from a plugin that was not loaded. */
const KINDS = {
  builtin: ['env', 'memory', 'dotenv', 'file'],
  plugin: [
    'hashicorp', 'boru', 'awssecrets', 'awsparams', 'gcpsecrets',
    'azuresecrets', 'onepassword', 'doppler', 'infisical', 'secretspec',
  ],
}

module.exports = { BUILTINS, KINDS }
