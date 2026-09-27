-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lean/plugins/SekretoPlugins/Infisical.lean)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/-
Infisical, as a voxgig/plugin definition.

A PLUGIN: it opens a socket, so it is not in the core and a chain may
name `infisical` only if the calling project passed this definition in.

A port of typescript/plugins/infisical.ts, which is canonical.
-/

import Sekreto.Text
import Sekreto.Json
import Sekreto.Core
import Sekreto.Provider
import Sekreto.Addr
import SekretoPlugins.Httpjson

namespace Sekreto

/-- Infisical.

`api.token` reads the secret keyed `API_TOKEN` at a secret path in one
environment of a project. Auth is a token, or a universal-auth (machine
identity) login with clientid/clientsecret - whose expiry field is
`expiresIn`, camelCase, unlike everyone else's `expires_in`. -/
def infisicalprovider (addr token clientid clientsecret project environment
    path : String := "") : IO Provider := do
  let livetoken ← IO.mkRef (none : Option String)
  let renewat ← IO.mkRef NEVER

  let login (useaddr : String) : IO String := do
    if !token.isEmpty then return token

    if clientid.isEmpty || clientsecret.isEmpty then
      fail "sekreto: infisical: no token and no client credentials"

    let body := Json.object [
      ("clientId", Json.str clientid),
      ("clientSecret", Json.str clientsecret)]

    let res ← fetchjson "POST" (useaddr ++ "/api/v1/auth/universal-auth/login")
      [("content-type", "application/json")] (some (Json.stringify body))

    match OptJson.text (OptJson.dig res.body ["accessToken"]) with
    | some value =>
      if 200 != res.status || value.isEmpty then
        fail ("sekreto: infisical login failed: " ++ toString res.status)
      renewat.set (← Sekreto.renewat (expiryof (OptJson.dig res.body ["expiresIn"])))
      return value
    | none => fail ("sekreto: infisical login failed: " ++ toString res.status)

  return {
    lookup := fun name => do
      let useaddr := trimslash (first [addr, "https://app.infisical.com"])
      ofResult (checkaddr useaddr)

      if project.isEmpty || environment.isEmpty then
        fail "sekreto: infisical: no project/environment"

      if (← livetoken.get).isNone || (← IO.monoMsNow) ≥ (← renewat.get) then
        livetoken.set (some (← login useaddr))

      -- envkey here takes NO prefix.
      let url := useaddr ++ "/api/v3/secrets/raw/" ++ (← ofResult (envkey name)) ++
        "?workspaceId=" ++ uriescape project ++
        "&environment=" ++ uriescape environment ++
        "&secretPath=" ++ uriescape (first [path, "/"])

      let res ← fetchjson "GET" url [("authorization", "Bearer " ++ ((← livetoken.get).getD ""))]

      if 404 == res.status then return none
      if 200 != res.status then fail ("sekreto: infisical error: " ++ toString res.status)

      return OptJson.text (OptJson.dig res.body ["secret", "secretValue"])
    describe := "infisical:" ++ project ++ "/" ++ environment }

/-- The `infisical` kind. -/
def infisical : Plugin.Definition := providerplugin "infisical" (fun spec =>
  infisicalprovider spec.addr spec.token spec.clientid spec.clientsecret spec.project
    spec.environment spec.path)

end Sekreto
