(* VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ocaml/plugins/aws.ml) *)
(* Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* The `awssecrets` and `awsparams` provider kinds, as voxgig/plugin
   definitions - and the SigV4 request signing they share.

   THE CORE OF NO PORT IMPORTS A HASH FUNCTION, which is why `Sigv4` and
   the SHA-256 under it are reached only from here. Two kinds in one
   module because they are one credential story and one signer; the
   catalog still sees two definitions with two names.

   A port of typescript/plugins/aws.ts, which is canonical. *)

open Secret
open Provider
open Httpjson

(* The `YYYYMMDDTHHMMSSZ` timestamp SigV4 wants, for now. The only place in
   this library that samples the clock for a signature; `Sigv4.sigv4` itself
   never does. *)
let awsnow () : string =
  let t = Unix.gmtime (Unix.gettimeofday ()) in
  Printf.sprintf "%04d%02d%02dT%02d%02d%02dZ" (t.Unix.tm_year + 1900) (t.Unix.tm_mon + 1)
    t.Unix.tm_mday t.Unix.tm_hour t.Unix.tm_min t.Unix.tm_sec

type awsauth = { aregion : string; akeyid : string; asecret : string; asession : string }

(* Region and credentials, from config first and the standard AWS_*
   environment variables second - those are AWS's own convention, and a pod
   or CI job that has them set should just work. Missing either is an error:
   an AWS store with no credentials could not answer. *)
let awsauthof (region : string) (keyid : string) (secret : string) (session : string) : awsauth =
  let useregion = firstof [ region; getenv "AWS_REGION"; getenv "AWS_DEFAULT_REGION" ] in
  let usekeyid = firstof [ keyid; getenv "AWS_ACCESS_KEY_ID" ] in
  let usesecret = firstof [ secret; getenv "AWS_SECRET_ACCESS_KEY" ] in
  let usesession = firstof [ session; getenv "AWS_SESSION_TOKEN" ] in

  if "" = useregion then fail "sekreto: aws: no region (set region or AWS_REGION)";

  if "" = usekeyid || "" = usesecret then
    fail "sekreto: aws: no credentials (set keyid/secret or AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY)";

  { aregion = useregion; akeyid = usekeyid; asecret = usesecret; asession = usesession }

(* One signed call to an AWS JSON-1.1 API. *)
let awscall (region : string) (keyid : string) (secret : string) (session : string)
    (addr : string) (service : string) (target : string) (payload : string) : answer =
  let auth = awsauthof region keyid secret session in

  (* The China partition lives under its own suffix; every other commercial
     region is plain amazonaws.com. *)
  let suffix =
    if String.starts_with ~prefix:"cn-" auth.aregion then ".amazonaws.com.cn" else ".amazonaws.com"
  in
  let useaddr = firstof [ addr; "https://" ^ service ^ "." ^ auth.aregion ^ suffix ] in
  checkaddr useaddr;

  let url = trimslash useaddr ^ "/" in

  let extras =
    [ ("content-type", "application/x-amz-json-1.1"); ("x-amz-target", target) ]
  in

  let signed =
    Sigv4.sigv4
      {
        Sigv4.smethod = "POST";
        url;
        service;
        region = auth.aregion;
        keyid = auth.akeyid;
        secret = auth.asecret;
        datetime = awsnow ();
        headers = extras;
        body = payload;
        session = auth.asession;
      }
  in

  fetchjson ~headers:(extras @ signed) ~body:payload "POST" url

(* Does this AWS error body name one of the not-found types? Those are a
   miss; every other failure is a store that could not answer. AWS sends
   `com.amazonaws...#ResourceNotFoundException`, so this contains rather
   than equals. *)
let awsmiss (body : Json.t option) (types : string list) : bool =
  match digstr body [ "__type" ] with
  | Some errtype -> List.exists (fun want -> None <> findsub errtype want) types
  | None -> false

(* AWS Secrets Manager.

   `api.token` reads the secret named `api` (the vaultref path, so
   `db.pass.main` reads `db/pass`) and takes the `token` field of its JSON
   SecretString - the AWS idiom of one JSON map per secret. A SecretString
   that is not JSON is the value itself, under the conventional field
   `value`. *)
let awssecrets_provider (region : string) (keyid : string) (secret : string) (session : string)
    (addr : string) : provider =
  {
    lookup =
      (fun name ->
        let ref_ = vaultref name in

        let res =
          awscall region keyid secret session addr "secretsmanager"
            "secretsmanager.GetSecretValue"
            (Json.stringify (Json.obj [ ("SecretId", Json.str ref_.path) ]))
        in

        if 400 = res.status && awsmiss res.jbody [ "ResourceNotFoundException" ] then None
        else if 200 <> res.status then
          fail ("sekreto: aws secretsmanager error: " ^ string_of_int res.status)
        else
          match digstr res.jbody [ "SecretString" ] with
          | None -> (
            (* A binary secret has no fields to address; only the
               conventional `value` field can mean "the bytes themselves". *)
            match digstr res.jbody [ "SecretBinary" ] with
            | Some raw when "value" = ref_.field -> (
              match Http.unbase64 raw with
              | Some bytes -> Some bytes
              | None -> fail "sekreto: aws secretsmanager: undecodable secret")
            | _ -> None)
          | Some text -> (
            match Json.parse text with
            | Some (Json.Obj fields) -> (
              match List.assoc_opt ref_.field fields with
              | Some value -> Json.text value
              | None -> None)
            (* A plain-string secret is the whole value; it has no named
               fields. *)
            | _ -> if "value" = ref_.field then Some text else None));
    (* Config only, never the environment: `describe` feeds the spec's
       sources group, which must answer the same everywhere. *)
    describe = (fun () -> "awssecrets:" ^ region);
  }

(* AWS SSM Parameter Store.

   `db.pass.main` reads the parameter `/db/pass/main` (under an optional
   prefix path), decrypted. Parameter Store carries flat strings, so there
   is no field indirection. *)
let awsparams_provider (region : string) (keyid : string) (secret : string) (session : string)
    (addr : string) (prefix : string) : provider =
  {
    lookup =
      (fun name ->
        let payload =
          Json.obj
            [ ("Name", Json.str (awsparam ~prefix name)); ("WithDecryption", Json.bool true) ]
        in

        let res =
          awscall region keyid secret session addr "ssm" "AmazonSSM.GetParameter"
            (Json.stringify payload)
        in

        if 400 = res.status && awsmiss res.jbody [ "ParameterNotFound" ] then None
        else if 200 <> res.status then fail ("sekreto: aws ssm error: " ^ string_of_int res.status)
        else digtext res.jbody [ "Parameter"; "Value" ]);
    describe = (fun () -> "awsparams:" ^ region ^ prefix);
  }

let secretsplugin () : Defs.definition =
  providerplugin "awssecrets" (fun spec ->
      awssecrets_provider spec.region spec.keyid spec.secret spec.session spec.addr)

let paramsplugin () : Defs.definition =
  providerplugin "awsparams" (fun spec ->
      awsparams_provider spec.region spec.keyid spec.secret spec.session spec.addr spec.prefix)
