-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lean/src/Sekreto/Builtin.lean)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/-
THE BUILT-IN PROVIDER KINDS - the same four in every port.

What makes a kind built in is that it needs nothing of the platform
beyond reading a local file: no socket, no TLS, no crypto, no child
process. These four are the floor every chain stands on, and a chain that
reads secrets from options, the environment, a plaintext `.env` and a
mounted secret directory works with no plugin loaded at all. Everything
else - the vault clients, the cloud stores, the two CLIs, and SigV4 with
them - is a voxgig/plugin definition under `plugins/`, and a chain may
name one only if the calling project handed it in.

A port of typescript/src/provider/builtin.ts, which is canonical.
-/

import Sekreto.Text
import Sekreto.Json
import Sekreto.Core
import Sekreto.Provider

namespace Sekreto

/-- Environment variables: `api.token` from `API_TOKEN`. -/
def envprovider (pre : String := "") : Provider := {
  lookup := fun name => do IO.getEnv (← ofResult (envkey name pre))
  describe := "env" ++ (if pre.isEmpty then "" else ":" ++ pre) }

/-- Literal values, keyed like environment variables. The spec uses this
to test chain behaviour without touching the outside world. An absent key
is a miss; the EMPTY STRING IS A HIT. -/
def memoryprovider (values : Pairs String := []) (pre : String := "") : Provider := {
  lookup := fun name => do return Pairs.find? values (← ofResult (envkey name pre))
  describe := "memory" ++ (if pre.isEmpty then "" else ":" ++ pre) }

/-- A `.env` file, read once, keyed exactly like the environment.

LAZILY: the `stores` corpus group puts a dotenv provider in a chain and
never looks anything up, so an eager constructor would read whatever
`.env` happened to sit in the working directory. -/
def dotenvprovider (file : String := ".env") (pre : String := "") : IO Provider := do
  let cell ← IO.mkRef (none : Option (Pairs String))

  let load : IO (Pairs String) := do
    match ← cell.get with
    | some held => return held
    | none =>
      let bytes ← tryCatch (readmaybe file)
        (fun err => fail ("sekreto: dotenv provider cannot read " ++ file ++ ": " ++ why err))
      let loaded := match bytes with
        | none => []
        | some held => parsedotenv (astext held)
      cell.set (some loaded)
      return loaded

  return {
    lookup := fun name => do
      let key ← ofResult (envkey name pre)
      return Pairs.find? (← load) key
    describe := "dotenv:" ++ file }

/-- A directory of one-secret-per-file entries, keyed like the
environment: `api.token` reads `<dir>/API_TOKEN`.

This is the shape of a mounted Kubernetes Secret, a Docker or Swarm
secret, and a systemd credentials directory, so those all work with no
further configuration. Read on EVERY lookup, with no caching. One
trailing newline is stripped - tools that write these files disagree
about it, and a newline is never part of a secret on purpose. -/
def fileprovider (dir : String := "") (pre : String := "") : Provider := {
  lookup := fun name => do
    let key ← ofResult (envkey name pre)
    let path := if dir.isEmpty then key else dropsuffix dir "/" ++ "/" ++ key
    let bytes ← tryCatch (readmaybe path)
      (fun err => fail ("sekreto: file provider cannot read " ++ path ++ ": " ++ why err))
    match bytes with
    | none => return none
    | some held =>
      let body := astext held
      return some (
        if body.endsWith "\r\n" then body.dropRight 2
        else if body.endsWith "\n" then body.dropRight 1
        else body)
  describe := "file:" ++ dir }

/-- The four built-in kinds, as voxgig/plugin definitions. They go into
every catalog first, so a plugin naming one of these names replaces it -
a host substituting an implementation, never an accident, because the
four names are documented. -/
def BUILTINS : List Plugin.Definition := [
  providerplugin "env" (fun spec => pure (envprovider spec.«prefix»)),
  providerplugin "memory" (fun spec => pure (memoryprovider spec.values spec.«prefix»)),
  providerplugin "dotenv" (fun spec =>
    dotenvprovider (if spec.file.isEmpty then ".env" else spec.file) spec.«prefix»),
  providerplugin "file" (fun spec => pure (fileprovider spec.dir spec.«prefix»))]

/-- The kinds built in here, in catalog order. -/
def BUILTINKINDS : List String := ["env", "memory", "dotenv", "file"]

/-- The kinds this library ships as PLUGINS, so that a kind nobody has
heard of can be told from one the caller did not pass in. Naming them
costs the core nothing: these are strings, not imports. -/
def PLUGINKINDS : List String := [
  "hashicorp", "boru", "awssecrets", "awsparams", "gcpsecrets",
  "azuresecrets", "onepassword", "doppler", "infisical", "secretspec"]

end Sekreto
