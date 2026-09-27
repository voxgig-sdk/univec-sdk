-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lean/plugins/SekretoPlugins/Boru.lean)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/-
boru, as a voxgig/plugin definition.

A PLUGIN: it spawns the boru binary, or dials boru's own wire protocol,
so it is not in the core and a chain may name `boru` only if the calling
project passed this definition in.

A port of typescript/plugins/boru.ts, which is canonical.
-/

import Sekreto.Text
import Sekreto.Json
import Sekreto.Core
import Sekreto.Provider
import Sekreto.Addr
import SekretoPlugins.Httpjson
import SekretoPlugins.Proc

namespace Sekreto

/-- Does this boru failure mean "no such secret" rather than "I could not
answer"? Matched on boru's own wording for a missing alias. -/
def borumiss (text : String) : Bool := hasText text "no alias named"

/-- A boru vault.

Two ways in, both boru's own.

With no `addr`, the CLI: `boru vault get --reveal <alias>` prints the
secret on stdout and nothing else. The passphrase is read by boru itself
from `BORU_VAULT_PASSPHRASE`; sekreto never accepts it as config and
never puts it on a command line, where it would show up in the process
table.

With an `addr`, boru's wire protocol: a read-only, HashiCorp-shaped
provision API authenticated by a capability token. A sekreto name is
already a valid boru alias, and BORU ALIASES KEEP THEIR DOTS, so
`api.token` is the single path segment `api.token` - not the `api`/`token`
split a HashiCorp KV gets. A 404 is a miss; anything else the server
refuses is an error. -/
def boruprovider (command space home addrgiven token mount : String := "") : Provider :=
  let usecommand := if command.isEmpty then "boru" else command
  let addr := trimslash addrgiven
  let usemount := if mount.isEmpty then "secret" else mount
  {
    lookup := fun name => do
      let _ ← ofResult (checkname name)

      if !addr.isEmpty then
        ofResult (checkaddr addr)
        let alias := if space.isEmpty then name else space ++ "/" ++ name
        let url := addr ++ "/v1/" ++ usemount ++ "/data/" ++ alias
        let res ← fetchjson "GET" url [("X-Vault-Token", token)]
        if 404 == res.status then return none
        if 200 != res.status then
          fail ("sekreto: boru serve error: " ++ toString res.status ++ ": " ++ url)
        return OptJson.text (OptJson.dig res.body ["data", "data", "value"])
      else
        let alias := if space.isEmpty then name else space ++ ":" ++ name
        let env := if home.isEmpty then [] else [("BORU_HOME", some home)]
        let ran ← runcmd usecommand ["vault", "get", "--reveal", alias] env

        if 0 == ran.status then
          -- boru prints the value and one newline, and nothing else.
          return some (dropsuffix ran.out "\n")
        -- "no alias named" is boru saying it does not hold this secret,
        -- which is a miss. A locked vault or a wrong passphrase is not.
        if borumiss ran.why then return none
        fail ("sekreto: boru vault error: " ++
          (if ran.why.isEmpty then "exit " ++ toString ran.status else ran.why))
    describe :=
      if !addr.isEmpty then "boru:" ++ addr
      else "boru" ++ (if space.isEmpty then "" else ":" ++ space) }

/-- The `boru` kind. -/
def boru : Plugin.Definition := providerplugin "boru" (fun spec =>
  pure (boruprovider spec.command spec.«namespace» spec.home spec.addr spec.token spec.mount))

end Sekreto
