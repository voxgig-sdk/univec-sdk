-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lean/plugins/SekretoPlugins/Hashicorp.lean)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/-
HashiCorp Vault, as a voxgig/plugin definition.

A PLUGIN: it opens a socket, so it is not in the core and a chain may
name `hashicorp` only if the calling project passed this definition in.

    import SekretoPlugins.Hashicorp

    sekreto { plugins := [hashicorp], providers := [
      { kind := "hashicorp", addr := "https://vault.example.com:8200" }] }

A port of typescript/plugins/hashicorp.ts, which is canonical.
-/

import Sekreto.Text
import Sekreto.Json
import Sekreto.Core
import Sekreto.Provider
import Sekreto.Addr
import SekretoPlugins.Httpjson

namespace Sekreto

/-- HashiCorp Vault.

KV v2 (the default): `api.token` reads `{addr}/v1/{mount}/data/api` and
takes the `token` field of `data.data`. KV v1 reads
`{addr}/v1/{mount}/api` and takes the field of `data`. A 404 means "not
here" - a miss - so a vault can sit in a chain with fallbacks.

A Vault Enterprise namespace rides the X-Vault-Namespace header, on
logins as well as reads.

Instead of being handed a token, the provider can log in: Kubernetes auth
(the pod's service-account JWT, from its conventional path) or AppRole. A
failed login is an error, never a miss - it means this store could not
answer at all. -/
def hashicorpprovider (addr : String) (token mount vaultnamespace : String := "")
    (kv : Option Nat := none) (auth : Option AuthSpec := none) : IO Provider := do
  let usemount := if mount.isEmpty then "secret" else mount
  let usekv := kv.getD 2

  -- A version typo like kv: 3 must not quietly behave as v2 and turn its
  -- 404s into misses; there is nothing safe to assume it meant.
  if 1 != usekv && 2 != usekv then
    fail ("sekreto: hashicorp: unsupported kv version: " ++ toString usekv)

  let livetoken ← IO.mkRef (if token.isEmpty then none else some token)
  let renewat ← IO.mkRef NEVER

  let baseheaders : Pairs String :=
    if vaultnamespace.isEmpty then [] else [("X-Vault-Namespace", vaultnamespace)]

  let login : IO String := do
    let use ← match auth with
      | some found => pure found
      | none => fail "sekreto: hashicorp: no token and no auth method"

    let authmount := first [use.mount, use.method]
    let url := trimslash addr ++ "/v1/auth/" ++ authmount ++ "/login"

    let body ←
      if "kubernetes" == use.method then do
        let jwt ←
          if !use.jwt.isEmpty then pure use.jwt
          else
            let file := first [use.jwtfile, "/var/run/secrets/kubernetes.io/serviceaccount/token"]
            match ← tryCatch (readmaybe file) (fun _ => pure none) with
            | some held => pure (astext held).trim
            | none => fail ("sekreto: hashicorp: cannot read jwt file " ++ file)
        pure (Json.object [("role", Json.str use.role), ("jwt", Json.str jwt)])
      else if "approle" == use.method then
        pure (Json.object [("role_id", Json.str use.roleid), ("secret_id", Json.str use.secretid)])
      else
        fail ("sekreto: hashicorp: unknown auth method: " ++ use.method)

    let res ← fetchjson "POST" url baseheaders (some (Json.stringify body))
    let got := OptJson.text (OptJson.dig res.body ["auth", "client_token"])

    match got with
    | some value =>
      if 200 != res.status || value.isEmpty then
        fail ("sekreto: hashicorp login failed: " ++ toString res.status ++ ": " ++ url)
      renewat.set (← Sekreto.renewat (expiryof (OptJson.dig res.body ["auth", "lease_duration"])))
      return value
    | none => fail ("sekreto: hashicorp login failed: " ++ toString res.status ++ ": " ++ url)

  return {
    lookup := fun name => do
      ofResult (checkaddr addr)

      let held ← livetoken.get
      if held.isNone || (← IO.monoMsNow) ≥ (← renewat.get) then
        livetoken.set (some (← login))

      let ref ← ofResult (vaultref name)
      let base := trimslash addr ++ "/v1/" ++ usemount
      let url := if 1 == usekv then base ++ "/" ++ ref.path else base ++ "/data/" ++ ref.path

      let headers := Pairs.put baseheaders "X-Vault-Token" ((← livetoken.get).getD "")
      let res ← fetchjson "GET" url headers

      if 404 == res.status then return none
      if 200 != res.status then
        fail ("sekreto: hashicorp error: " ++ toString res.status ++ ": " ++ url)

      let data := if 1 == usekv then OptJson.dig res.body ["data"]
                  else OptJson.dig res.body ["data", "data"]
      return OptJson.text (OptJson.dig data [ref.field])
    describe := "hashicorp:" ++ addr ++ "/" ++ usemount }

/-- The `hashicorp` kind. -/
def hashicorp : Plugin.Definition := providerplugin "hashicorp" (fun spec =>
  hashicorpprovider spec.addr spec.token spec.mount spec.vaultnamespace spec.kv spec.auth)

end Sekreto
