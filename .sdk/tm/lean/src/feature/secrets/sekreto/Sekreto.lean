-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lean/src/Sekreto.lean)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/-
sekreto - one interface for secrets, wherever they live.

The core, in one import. Everything below is in the `Sekreto` namespace,
so a consumer writes `import Sekreto` and either `open Sekreto` or
qualifies.

    let secrets ← sekreto { providers := [
      { kind := "env" },
      { kind := "dotenv", file := ".env" }] }

    let token ← secrets.get "api.token"

Four kinds are built in - `env`, `memory`, `dotenv` and `file` - and a
chain of them needs nothing further. Every kind that opens a socket,
signs a request or spawns a process is a voxgig/plugin definition under
`plugins/`, imported and passed by the calling project:

    import SekretoPlugins.Hashicorp

    let secrets ← sekreto {
      plugins := [hashicorp],
      providers := [{ kind := "hashicorp", addr := "https://vault.example.com:8200" }] }

Two ways to read. `get` is transparent - it walks the chain and takes the
first hit. `getfrom` is directed - it names the store, and only that
store is asked.

Nothing here reaches the network until the first lookup: construction
validates, and contacts nothing.
-/

import Sekreto.Text
import Sekreto.Json
import Sekreto.Core
import Sekreto.Addr
import Sekreto.Provider
import Sekreto.Builtin
import Sekreto.Chain
