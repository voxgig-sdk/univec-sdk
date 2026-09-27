-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lean/plugins/SekretoPlugins/Secretspec.lean)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/-
SecretSpec, as a voxgig/plugin definition.

A PLUGIN: it spawns the secretspec binary, so it is not in the core and a
chain may name `secretspec` only if the calling project passed this
definition in.

THE ONLY PLUGIN THAT LINKS NO HTTP CLIENT. It reads its own CLI and
nothing else, so it takes `Proc` and no TLS anywhere in its closure. If
that ever stops being true it is a real change, not a tidy-up.

A port of typescript/plugins/secretspec.ts, which is canonical.
-/

import Sekreto.Text
import Sekreto.Json
import Sekreto.Core
import Sekreto.Provider
import SekretoPlugins.Proc

namespace Sekreto

/-- Does this SecretSpec failure mean "no such secret" rather than "I
could not answer"?

MATCHED ON THE WHOLE PHRASE, NOT ON "not found". SecretSpec also says
`Provider backend 'keyring' not found`, which is a store that could not
answer at all - and reading that as a miss is the worst failure this
library has, because the chain then falls through to a weaker store
without saying so. The key is required to appear, so the two cannot be
confused. -/
def secretspecmiss (text key : String) : Bool :=
  hasText text ("Secret '" ++ key ++ "' not found")

/-- SecretSpec (https://secretspec.dev), through its CLI.

`secretspec get API_TOKEN` prints the value on stdout and nothing else. A
sekreto name maps to a SecretSpec key exactly as it maps to an
environment variable.

A reason is required, not optional: SecretSpec records every read in an
audit log and refuses to read at all without one. -/
def secretspecprovider (command file profile backend reason pre : String := "") : Provider :=
  let usecommand := if command.isEmpty then "secretspec" else command
  {
    lookup := fun name => do
      let key ← ofResult (envkey name pre)

      -- The order is exact: `--file` before the subcommand, `--reason`
      -- always sent.
      let args :=
        (if file.isEmpty then [] else ["--file", file]) ++
        ["get", key] ++
        (if backend.isEmpty then [] else ["--provider", backend]) ++
        (if profile.isEmpty then [] else ["--profile", profile]) ++
        ["--reason", first [reason, "sekreto"]]

      let ran ← runcmd usecommand args

      if 0 == ran.status then return some (dropsuffix ran.out "\n")
      if secretspecmiss ran.why key then return none
      fail ("sekreto: secretspec error: " ++
        (if ran.why.isEmpty then "exit " ++ toString ran.status else ran.why))
    describe := "secretspec" ++ (if backend.isEmpty then "" else ":" ++ backend) }

/-- The `secretspec` kind. -/
def secretspec : Plugin.Definition := providerplugin "secretspec" (fun spec =>
  pure (secretspecprovider spec.command spec.file spec.profile spec.backend spec.reason
    spec.«prefix»))

end Sekreto
