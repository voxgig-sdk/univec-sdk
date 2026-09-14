// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (javascript/plugins/secretspec.js)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */

// A port of typescript/plugins/secretspec.ts, which is canonical.

const {
  SekretoError, envkey, nodemod, providerplugin,
} = require('../provider/support')

/** SecretSpec (https://secretspec.dev).
 *
 * SecretSpec is a declaration - a `secretspec.toml` naming the secrets a
 * project needs - plus a chain of its own backends to satisfy them from.
 * That makes it the same shape as sekreto one level down, and the reason
 * to support it is the same reason sekreto exists: a project that has
 * already declared its secrets there should not have to declare them
 * again here.
 *
 * Read through its CLI, as boru is, because that is the interface it
 * offers a program in another language: `secretspec get API_TOKEN`
 * prints the value on stdout and nothing else. A sekreto name maps to a
 * SecretSpec key exactly as it maps to an environment variable -
 * `api.token` is `API_TOKEN`.
 *
 * `backend` selects one of SecretSpec's backends (`--provider`, e.g.
 * `keyring` or `dotenv://.env`) and is called `backend` here only
 * because `provider` already means something else in this library.
 *
 * A reason is required, not optional: SecretSpec records every read in
 * an audit log and refuses to read at all without one. */
function secretspecprovider(options) {
  const opts = options || {}
  const command = opts.command || 'secretspec'

  return {
    lookup: (name) => {
      const key = envkey(name, opts.prefix)

      const args = []
      if (opts.file) {
        args.push('--file', opts.file)
      }
      args.push('get', key)
      if (opts.backend) {
        args.push('--provider', opts.backend)
      }
      if (opts.profile) {
        args.push('--profile', opts.profile)
      }
      args.push('--reason', opts.reason || 'sekreto')

      const { spawnSync } = nodemod('node:child_process')
      const run = spawnSync(command, args, { encoding: 'utf8' })

      if (run.error) {
        throw new SekretoError('sekreto: cannot run ' + command + ': ' + run.error.message)
      }

      if (0 === run.status) {
        // The value and one newline, and nothing else.
        return run.stdout.replace(/\n$/, '')
      }

      const why = (run.stderr || '').trim()

      if (secretspecmiss(why, key)) {
        return undefined
      }

      throw new SekretoError('sekreto: secretspec error: ' + (why || 'exit ' + run.status))
    },
    describe: () => 'secretspec' + (opts.backend ? ':' + opts.backend : ''),
  }
}

/** Does this SecretSpec failure mean "no such secret" rather than "I
 * could not answer"?
 *
 * SecretSpec says `Secret 'API_TOKEN' not found` for both a name it does
 * not declare and one declared with no value, and both are misses.
 *
 * MATCHED ON THE WHOLE PHRASE, NOT ON "not found". SecretSpec also says
 * `Provider backend 'keyring' not found`, which is a store that could
 * not answer at all - and reading that as a miss is the worst failure
 * this library has, because the chain then falls through to a weaker
 * store without saying so. */
function secretspecmiss(why, key) {
  return why.includes("Secret '" + key + "' not found")
}

/** The plugin. Needs a child process. */
const secretspec = providerplugin('secretspec', (spec) =>
  secretspecprovider({
    command: spec.command,
    file: spec.file,
    profile: spec.profile,
    backend: spec.backend,
    reason: spec.reason,
    prefix: spec.prefix,
  }),
)

module.exports = { secretspec, secretspecprovider }
