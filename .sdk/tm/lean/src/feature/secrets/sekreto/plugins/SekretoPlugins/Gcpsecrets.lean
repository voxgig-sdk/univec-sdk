-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lean/plugins/SekretoPlugins/Gcpsecrets.lean)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/-
GCP Secret Manager, as a voxgig/plugin definition.

A PLUGIN: it opens a socket, so it is not in the core and a chain may
name `gcpsecrets` only if the calling project passed this definition in.

A port of typescript/plugins/gcpsecrets.ts, which is canonical.
-/

import Sekreto.Text
import Sekreto.Json
import Sekreto.Core
import Sekreto.Provider
import Sekreto.Addr
import SekretoPlugins.Httpjson

namespace Sekreto

/-- GCP Secret Manager.

`api.token` reads secret `api_token` (dots flattened to `_`; Secret
Manager ids have no hierarchy and reject dots), latest version. The token
comes from config, then `GOOGLE_OAUTH_ACCESS_TOKEN`, then the GCE/GKE
metadata server - so on Google's own platform no credential configuration
is needed at all.

The metadata call is plain http to a link-local host by platform design
and carries no credential, so `checkaddr` guards the Secret Manager
address instead. -/
def gcpsecretsprovider (project token addr metadataaddr : String := "") : IO Provider := do
  let livetoken ← IO.mkRef (none : Option String)
  let renewat ← IO.mkRef NEVER

  let login : IO String := do
    let configured := first [token, ← getenv "GOOGLE_OAUTH_ACCESS_TOKEN"]
    if !configured.isEmpty then return configured

    let host ← getenv "GCE_METADATA_HOST"
    let usemeta := first [metadataaddr,
      if host.isEmpty then "" else "http://" ++ host,
      "http://metadata.google.internal"]

    let url := trimslash usemeta ++
      "/computeMetadata/v1/instance/service-accounts/default/token"
    let res ← fetchjson "GET" url [("Metadata-Flavor", "Google")]

    match OptJson.text (OptJson.dig res.body ["access_token"]) with
    | some value =>
      if 200 != res.status || value.isEmpty then
        fail "sekreto: gcp: no token and metadata server did not answer"
      renewat.set (← Sekreto.renewat (expiryof (OptJson.dig res.body ["expires_in"])))
      return value
    | none => fail "sekreto: gcp: no token and metadata server did not answer"

  return {
    lookup := fun name => do
      if project.isEmpty then fail "sekreto: gcp: no project"

      let useaddr := first [addr, "https://secretmanager.googleapis.com"]
      ofResult (checkaddr useaddr)

      if (← livetoken.get).isNone || (← IO.monoMsNow) ≥ (← renewat.get) then
        livetoken.set (some (← login))

      let url := trimslash useaddr ++ "/v1/projects/" ++ project ++ "/secrets/" ++
        (← ofResult (flatname name "_")) ++ "/versions/latest:access"

      let res ← fetchjson "GET" url [("authorization", "Bearer " ++ ((← livetoken.get).getD ""))]

      if 404 == res.status then return none
      if 200 != res.status then
        fail ("sekreto: gcp error: " ++ toString res.status ++ ": " ++ url)

      match OptJson.asstr (OptJson.dig res.body ["payload", "data"]) with
      | none => return none
      | some data =>
        match unbase64text data with
        | some decoded => return some decoded
        | none => fail "sekreto: gcp: undecodable secret"
    describe := "gcpsecrets:" ++ project }

/-- The `gcpsecrets` kind. -/
def gcpsecrets : Plugin.Definition := providerplugin "gcpsecrets" (fun spec =>
  gcpsecretsprovider spec.project spec.token spec.addr spec.metadataaddr)

end Sekreto
