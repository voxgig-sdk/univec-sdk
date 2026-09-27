-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lean/plugins/SekretoPlugins/Aws.lean)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/-
AWS Secrets Manager and SSM Parameter Store, as voxgig/plugin
definitions.

TWO KINDS IN ONE MODULE, and SigV4 travels with them. The AWS providers
are the only thing in this library that signs a request, so the digest
(`SekretoPlugins.Crypto`), the signer (`SekretoPlugins.Sigv4`) and the
wall clock the signature is stamped with (`SekretoPlugins.Clock`) are all
inside this plugin. The core of no port imports a hash function.

A port of typescript/plugins/aws.ts, which is canonical.
-/

import Sekreto.Text
import Sekreto.Json
import Sekreto.Core
import Sekreto.Provider
import Sekreto.Addr
import SekretoPlugins.Httpjson
import SekretoPlugins.Crypto
import SekretoPlugins.Clock
import SekretoPlugins.Sigv4

namespace Sekreto

/-- Region and credentials, from config first and the standard AWS_*
environment variables second - those are AWS's own convention, and a pod
or CI job that has them set should just work. Missing either is an error:
an AWS store with no credentials could not answer. -/
def awsauth (region keyid secret session : String) : IO (String × String × String × String) := do
  let useregion := first [region, ← getenv "AWS_REGION", ← getenv "AWS_DEFAULT_REGION"]
  let usekeyid := first [keyid, ← getenv "AWS_ACCESS_KEY_ID"]
  let usesecret := first [secret, ← getenv "AWS_SECRET_ACCESS_KEY"]
  let usesession := first [session, ← getenv "AWS_SESSION_TOKEN"]

  if useregion.isEmpty then
    fail "sekreto: aws: no region (set region or AWS_REGION)"

  if usekeyid.isEmpty || usesecret.isEmpty then
    fail ("sekreto: aws: no credentials" ++
      " (set keyid/secret or AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY)")

  return (useregion, usekeyid, usesecret, usesession)

/-- One signed call to an AWS JSON-1.1 API. -/
def awscall (region keyid secret session addr service target payload : String) : IO Answer := do
  let (useregion, usekeyid, usesecret, usesession) ← awsauth region keyid secret session

  -- The China partition lives under its own suffix; every other
  -- commercial region is plain amazonaws.com.
  let suffix := if useregion.startsWith "cn-" then ".amazonaws.com.cn" else ".amazonaws.com"
  let useaddr := first [addr, "https://" ++ service ++ "." ++ useregion ++ suffix]
  ofResult (checkaddr useaddr)

  let url := trimslash useaddr ++ "/"

  let extras : Pairs String := [
    ("content-type", "application/x-amz-json-1.1"),
    ("x-amz-target", target)]

  let signed := sigv4 {
    method := "POST", url := url, service := service, region := useregion,
    keyid := usekeyid, secret := usesecret, datetime := ← awsnow,
    headers := extras, body := payload, session := usesession }

  fetchjson "POST" url (signed.foldl (fun out kv => Pairs.put out kv.1 kv.2) extras) (some payload)

/-- Does this AWS error body name one of the not-found types? Those are a
miss; every other failure is a store that could not answer. AWS sends
`com.amazonaws...#ResourceNotFoundException`, so this CONTAINS. -/
def awsmiss (body : Option Json) (want : String) : Bool :=
  match OptJson.asstr (OptJson.dig body ["__type"]) with
  | some errtype => hasText errtype want
  | none => false

/-- AWS Secrets Manager.

`api.token` reads the secret named `api` (the vaultref path) and takes the
`token` field of its JSON SecretString - the AWS idiom of one JSON map per
secret. A SecretString that is not JSON is the value itself, under the
conventional field `value`. -/
def awssecretsprovider (region keyid secret session addr : String := "") : Provider := {
  lookup := fun name => do
    let ref ← ofResult (vaultref name)

    let res ← awscall region keyid secret session addr "secretsmanager"
      "secretsmanager.GetSecretValue"
      (Json.stringify (Json.object [("SecretId", Json.str ref.path)]))

    if 400 == res.status && awsmiss res.body "ResourceNotFoundException" then return none
    if 200 != res.status then
      fail ("sekreto: aws secretsmanager error: " ++ toString res.status)

    match OptJson.asstr (OptJson.dig res.body ["SecretString"]) with
    | none =>
      -- A binary secret has no fields to address; only the conventional
      -- `value` field can mean "the bytes themselves".
      match OptJson.asstr (OptJson.dig res.body ["SecretBinary"]) with
      | some encoded =>
        if "value" != ref.field then return none
        match unbase64text encoded with
        | some decoded => return some decoded
        | none => fail "sekreto: aws secretsmanager: undecodable secret"
      | none => return none
    | some text =>
      match Json.parse text with
      | some (.obj fields) => return OptJson.text (Pairs.find? fields ref.field)
      -- A plain-string secret is the whole value; it has no named fields.
      | _ => return (if "value" == ref.field then some text else none)
  -- Config only, never the environment: describe feeds the spec's
  -- sources group, which must answer the same everywhere.
  describe := "awssecrets:" ++ region }

/-- AWS SSM Parameter Store.

`db.pass.main` reads the parameter `/db/pass/main` (under an optional
prefix path), decrypted. Parameter Store carries flat strings, so there
is no field indirection. -/
def awsparamsprovider (region keyid secret session addr pre : String := "") : Provider := {
  lookup := fun name => do
    let payload := Json.object [
      ("Name", Json.str (← ofResult (awsparam name pre))),
      ("WithDecryption", Json.bool true)]

    let res ← awscall region keyid secret session addr "ssm" "AmazonSSM.GetParameter"
      (Json.stringify payload)

    if 400 == res.status && awsmiss res.body "ParameterNotFound" then return none
    if 200 != res.status then fail ("sekreto: aws ssm error: " ++ toString res.status)

    return OptJson.text (OptJson.dig res.body ["Parameter", "Value"])
  describe := "awsparams:" ++ region ++ pre }

/-- The `awssecrets` kind. -/
def awssecrets : Plugin.Definition := providerplugin "awssecrets" (fun spec =>
  pure (awssecretsprovider spec.region spec.keyid spec.secret spec.session spec.addr))

/-- The `awsparams` kind. -/
def awsparams : Plugin.Definition := providerplugin "awsparams" (fun spec =>
  pure (awsparamsprovider spec.region spec.keyid spec.secret spec.session spec.addr
    spec.«prefix»))

end Sekreto
