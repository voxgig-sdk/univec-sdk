(* VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ocaml/plugins/gcpsecrets.ml) *)
(* Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* The `gcpsecrets` provider kind, as a voxgig/plugin definition.

   Google Secret Manager over HTTPS, with the metadata server as the
   fallback source of a token.

   A port of typescript/plugins/gcpsecrets.ts, which is canonical. *)

open Secret
open Provider
open Httpjson

(* GCP Secret Manager.

   `api.token` reads secret `api_token` (dots flattened to `_`; Secret
   Manager ids have no hierarchy and reject dots), latest version. The token
   comes from config, then GOOGLE_OAUTH_ACCESS_TOKEN, then the GCE/GKE
   metadata server - so on Google's own platform no credential configuration
   is needed at all.

   The metadata call itself is plain http to a link-local host by platform
   design and carries no credential, so `checkaddr` guards the Secret
   Manager address instead. *)
let gcpsecrets_provider (project : string) (token : string) (addr : string)
    (metadataaddr : string) : provider =
  let livetoken = ref None in
  let renewat = ref never in

  let usemetadataaddr () =
    if "" <> metadataaddr then metadataaddr
    else
      let host = getenv "GCE_METADATA_HOST" in
      if "" <> host then "http://" ^ host else "http://metadata.google.internal"
  in

  let login () =
    let configured = firstof [ token; getenv "GOOGLE_OAUTH_ACCESS_TOKEN" ] in
    if "" <> configured then configured
    else begin
      let url =
        trimslash (usemetadataaddr ()) ^ "/computeMetadata/v1/instance/service-accounts/default/token"
      in

      let res = fetchjson ~headers:[ ("Metadata-Flavor", "Google") ] "GET" url in
      let got = digtext res.jbody [ "access_token" ] in

      if 200 <> res.status || not (isset got) then
        fail "sekreto: gcp: no token and metadata server did not answer";

      renewat := renewtime (Json.odig res.jbody [ "expires_in" ]);
      Option.get got
    end
  in

  {
    lookup =
      (fun name ->
        if "" = project then fail "sekreto: gcp: no project";

        let useaddr = firstof [ addr; "https://secretmanager.googleapis.com" ] in
        checkaddr useaddr;

        if None = !livetoken || nowms () >= !renewat then livetoken := Some (login ());

        let url =
          trimslash useaddr ^ "/v1/projects/" ^ project ^ "/secrets/" ^ flatname name "_"
          ^ "/versions/latest:access"
        in

        let res =
          fetchjson
            ~headers:[ ("authorization", "Bearer " ^ Option.value ~default:"" !livetoken) ]
            "GET" url
        in

        if 404 = res.status then None
        else if 200 <> res.status then
          fail ("sekreto: gcp error: " ^ string_of_int res.status ^ ": " ^ url)
        else
          match digstr res.jbody [ "payload"; "data" ] with
          | None -> None
          | Some data -> (
            match Http.unbase64 data with
            | Some bytes -> Some bytes
            | None -> fail "sekreto: gcp: undecodable secret"));
    describe = (fun () -> "gcpsecrets:" ^ project);
  }

let plugin () : Defs.definition =
  providerplugin "gcpsecrets" (fun spec ->
      gcpsecrets_provider spec.project spec.token spec.addr spec.metadataaddr)
