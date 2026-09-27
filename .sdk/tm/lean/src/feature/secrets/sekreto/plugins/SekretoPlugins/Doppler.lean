-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lean/plugins/SekretoPlugins/Doppler.lean)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/-
Doppler, as a voxgig/plugin definition.

A PLUGIN: it opens a socket, so it is not in the core and a chain may
name `doppler` only if the calling project passed this definition in.

A port of typescript/plugins/doppler.ts, which is canonical.
-/

import Sekreto.Text
import Sekreto.Json
import Sekreto.Core
import Sekreto.Provider
import Sekreto.Addr
import SekretoPlugins.Httpjson

namespace Sekreto

/-- Doppler.

The whole config is downloaded once - Doppler's own bulk endpoint - and
answered from memory, like a remote .env: `api.token` is the `API_TOKEN`
entry. A FAILED LOAD CACHES NOTHING, so it is retried. -/
def dopplerprovider (token project config addr : String := "") : IO Provider := do
  let cell ← IO.mkRef (none : Option (Pairs String))

  let load : IO (Pairs String) := do
    match ← cell.get with
    | some held => return held
    | none =>
      let useaddr := trimslash (first [addr, "https://api.doppler.com"])
      ofResult (checkaddr useaddr)

      let url := useaddr ++ "/v3/configs/config/secrets/download?format=json" ++
        (if project.isEmpty then "" else "&project=" ++ uriescape project) ++
        (if config.isEmpty then "" else "&config=" ++ uriescape config)

      let res ← fetchjson "GET" url [("authorization", "Bearer " ++ token)]

      match OptJson.asobj res.body with
      | none => fail ("sekreto: doppler error: " ++ toString res.status)
      | some body =>
        if 200 != res.status then fail ("sekreto: doppler error: " ++ toString res.status)
        let loaded := body.foldl (fun out kv =>
          match Json.text kv.2 with
          | some value => Pairs.put out kv.1 value
          | none => out) ([] : Pairs String)
        cell.set (some loaded)
        return loaded

  return {
    -- The `prefix` option is not consulted by this kind.
    lookup := fun name => do return Pairs.find? (← load) (← ofResult (envkey name))
    describe := "doppler" ++
      (if project.isEmpty then "" else ":" ++ project ++ "/" ++ config) }

/-- The `doppler` kind. -/
def doppler : Plugin.Definition := providerplugin "doppler" (fun spec =>
  dopplerprovider spec.token spec.project spec.config spec.addr)

end Sekreto
