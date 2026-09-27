-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lean/plugins/SekretoPlugins/Azuresecrets.lean)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/-
Azure Key Vault, as a voxgig/plugin definition.

A PLUGIN: it opens a socket, so it is not in the core and a chain may
name `azuresecrets` only if the calling project passed this definition
in.

A port of typescript/plugins/azuresecrets.ts, which is canonical.
-/

import Sekreto.Text
import Sekreto.Json
import Sekreto.Core
import Sekreto.Provider
import Sekreto.Addr
import SekretoPlugins.Httpjson

namespace Sekreto

/-- The Key Vault audience an Azure token is minted for. -/
private def AZURERESOURCE : String := "https://vault.azure.net"

/-- Azure Key Vault.

`api.token` reads secret `api-token` (dots flattened to `-`; Key Vault
names allow nothing else), current version. The token comes from config,
then a client-credentials login when tenant/clientid/clientsecret are
given, then the IMDS managed-identity endpoint.

As with GCP, the IMDS call is plain http to a link-local host by platform
design and carries no credential; the login and vault addresses are
`checkaddr`-guarded. -/
def azuresecretsprovider (vault token tenant clientid clientsecret loginaddr imdsaddr
    apiversion : String := "") : IO Provider := do
  let livetoken ← IO.mkRef (none : Option String)
  let renewat ← IO.mkRef NEVER

  let login : IO String := do
    if !token.isEmpty then return token

    if !tenant.isEmpty && !clientid.isEmpty && !clientsecret.isEmpty then
      let useloginaddr := first [loginaddr, "https://login.microsoftonline.com"]
      ofResult (checkaddr useloginaddr)

      let url := trimslash useloginaddr ++ "/" ++ tenant ++ "/oauth2/v2.0/token"
      let form := "grant_type=client_credentials&client_id=" ++ uriescape clientid ++
        "&client_secret=" ++ uriescape clientsecret ++
        "&scope=" ++ uriescape (AZURERESOURCE ++ "/.default")

      let res ← fetchjson "POST" url
        [("content-type", "application/x-www-form-urlencoded")] (some form)

      match OptJson.text (OptJson.dig res.body ["access_token"]) with
      | some value =>
        if 200 != res.status || value.isEmpty then
          fail ("sekreto: azure login failed: " ++ toString res.status)
        renewat.set (← Sekreto.renewat (expiryof (OptJson.dig res.body ["expires_in"])))
        return value
      | none => fail ("sekreto: azure login failed: " ++ toString res.status)
    else
      let imds := trimslash (first [imdsaddr, "http://169.254.169.254"]) ++
        "/metadata/identity/oauth2/token?api-version=2018-02-01&resource=" ++
        uriescape AZURERESOURCE

      let res ← fetchjson "GET" imds [("Metadata", "true")]

      match OptJson.text (OptJson.dig res.body ["access_token"]) with
      | some value =>
        if 200 != res.status || value.isEmpty then
          fail "sekreto: azure: no token, no client credentials, and IMDS did not answer"
        renewat.set (← Sekreto.renewat (expiryof (OptJson.dig res.body ["expires_in"])))
        return value
      | none => fail "sekreto: azure: no token, no client credentials, and IMDS did not answer"

  return {
    lookup := fun name => do
      if vault.isEmpty then fail "sekreto: azure: no vault"

      -- Only an explicit scheme is a URL; a vault NAMED httpvault must
      -- still become https://httpvault.vault.azure.net.
      let vaulturl :=
        if vault.startsWith "http://" || vault.startsWith "https://" then vault
        else "https://" ++ vault ++ ".vault.azure.net"
      ofResult (checkaddr vaulturl)

      if (← livetoken.get).isNone || (← IO.monoMsNow) ≥ (← renewat.get) then
        livetoken.set (some (← login))

      let url := trimslash vaulturl ++ "/secrets/" ++ (← ofResult (flatname name "-")) ++
        "?api-version=" ++ first [apiversion, "7.4"]

      let res ← fetchjson "GET" url [("authorization", "Bearer " ++ ((← livetoken.get).getD ""))]

      if 404 == res.status then return none
      if 200 != res.status then
        fail ("sekreto: azure error: " ++ toString res.status ++ ": " ++ bareurl url)

      return OptJson.text (OptJson.dig res.body ["value"])
    describe := "azuresecrets:" ++ vault }

/-- The `azuresecrets` kind. -/
def azuresecrets : Plugin.Definition := providerplugin "azuresecrets" (fun spec =>
  azuresecretsprovider spec.vault spec.token spec.tenant spec.clientid spec.clientsecret
    spec.loginaddr spec.imdsaddr spec.apiversion)

end Sekreto
