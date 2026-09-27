-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lean/plugins/SekretoPlugins/Onepassword.lean)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/-
1Password, through a Connect server, as a voxgig/plugin definition.

A PLUGIN: it opens a socket, so it is not in the core and a chain may
name `onepassword` only if the calling project passed this definition in.

A port of typescript/plugins/onepassword.ts, which is canonical.
-/

import Sekreto.Text
import Sekreto.Json
import Sekreto.Core
import Sekreto.Provider
import Sekreto.Addr
import SekretoPlugins.Httpjson

namespace Sekreto

/-- 1Password, through a Connect server.

The item titled `api.token` (titles keep their dots), in the named vault.
The value is the field with purpose PASSWORD, or the field labelled
`value`. A VAULT THAT CANNOT BE FOUND IS AN ERROR - config names it, so
its absence is a broken store, not a missing secret. -/
def onepasswordprovider (addr token vault : String := "") : IO Provider := do
  let vaultid ← IO.mkRef (none : Option String)

  let auth : Pairs String := [("authorization", "Bearer " ++ token)]

  let resolvevault (useaddr : String) : IO String := do
    if vault.isEmpty then fail "sekreto: onepassword: no vault"

    let res ← fetchjson "GET" (useaddr ++ "/v1/vaults") auth

    match OptJson.asarr res.body with
    | none => fail ("sekreto: onepassword error: " ++ toString res.status ++ ": listing vaults")
    | some list =>
      if 200 != res.status then
        fail ("sekreto: onepassword error: " ++ toString res.status ++ ": listing vaults")
      match list.find? (fun entry =>
          OptJson.text (entry.get? "id") == some vault ||
          OptJson.text (entry.get? "name") == some vault) with
      | some entry => return (OptJson.text (entry.get? "id")).getD ""
      | none => fail ("sekreto: onepassword: no vault named " ++ vault)

  return {
    lookup := fun name => do
      let _ ← ofResult (checkname name)

      let useaddr := trimslash addr
      if useaddr.isEmpty then fail "sekreto: onepassword: no addr"
      ofResult (checkaddr useaddr)

      let id ← match ← vaultid.get with
        | some held => pure held
        | none =>
          let found ← resolvevault useaddr
          vaultid.set (some found)
          pure found

      let filter := uriescape ("title eq \"" ++ name ++ "\"")
      let found ← fetchjson "GET" (useaddr ++ "/v1/vaults/" ++ id ++ "/items?filter=" ++ filter) auth

      match OptJson.asarr found.body with
      | none => fail ("sekreto: onepassword error: " ++ toString found.status ++ ": finding " ++ name)
      | some items =>
        if 200 != found.status then
          fail ("sekreto: onepassword error: " ++ toString found.status ++ ": finding " ++ name)
        match items with
        | [] => return none
        | head :: _ =>
          let itemid := (OptJson.text (head.get? "id")).getD ""
          let item ← fetchjson "GET" (useaddr ++ "/v1/vaults/" ++ id ++ "/items/" ++ itemid) auth
          if 200 != item.status then
            fail ("sekreto: onepassword error: " ++ toString item.status ++ ": reading " ++ name)

          let fields := (OptJson.asarr (OptJson.dig item.body ["fields"])).getD []

          -- Two full passes, in this order.
          match fields.find? (fun field => OptJson.asstr (field.get? "purpose") == some "PASSWORD") with
          | some field => return OptJson.text (field.get? "value")
          | none =>
            match fields.find? (fun field => OptJson.asstr (field.get? "label") == some "value") with
            | some field => return OptJson.text (field.get? "value")
            | none => return none
    describe := "onepassword:" ++ vault }

/-- The `onepassword` kind. -/
def onepassword : Plugin.Definition := providerplugin "onepassword" (fun spec =>
  onepasswordprovider spec.addr spec.token spec.vault)

end Sekreto
