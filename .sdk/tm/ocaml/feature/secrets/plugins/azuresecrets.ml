(* VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ocaml/plugins/azuresecrets.ml) *)
(* Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* The `azuresecrets` provider kind, as a voxgig/plugin definition.

   Azure Key Vault over HTTPS, with client credentials or IMDS as the
   source of a token.

   A port of typescript/plugins/azuresecrets.ts, which is canonical. *)

open Secret
open Provider
open Httpjson

(* The Key Vault audience an Azure token is minted for. *)
let azureresource = "https://vault.azure.net"

(* Azure Key Vault.

   `api.token` reads secret `api-token` (dots flattened to `-`; Key Vault
   names allow nothing else), current version. The token comes from config,
   then a client-credentials login when tenant/clientid/clientsecret are
   given, then the IMDS managed-identity endpoint.

   As with GCP, the IMDS call is plain http to a link-local host by platform
   design and carries no credential; the login and vault addresses are
   `checkaddr`-guarded. IMDS answers `expires_in` as a STRING, which is why
   `renewtime` accepts one. *)
let azuresecrets_provider (vault : string) (token : string) (tenant : string) (clientid : string)
    (clientsecret : string) (loginaddr : string) (imdsaddr : string) (apiversion : string) :
    provider =
  let livetoken = ref None in
  let renewat = ref never in

  let login () =
    if "" <> token then token
    else if "" <> tenant && "" <> clientid && "" <> clientsecret then begin
      let useloginaddr = firstof [ loginaddr; "https://login.microsoftonline.com" ] in
      checkaddr useloginaddr;

      let url = trimslash useloginaddr ^ "/" ^ tenant ^ "/oauth2/v2.0/token" in
      let form =
        "grant_type=client_credentials&client_id=" ^ Sigv4.uriescape clientid ^ "&client_secret="
        ^ Sigv4.uriescape clientsecret ^ "&scope="
        ^ Sigv4.uriescape (azureresource ^ "/.default")
      in

      let res =
        fetchjson
          ~headers:[ ("content-type", "application/x-www-form-urlencoded") ]
          ~body:form "POST" url
      in

      let got = digtext res.jbody [ "access_token" ] in
      if 200 <> res.status || not (isset got) then
        fail ("sekreto: azure login failed: " ^ string_of_int res.status);

      renewat := renewtime (Json.odig res.jbody [ "expires_in" ]);
      Option.get got
    end
    else begin
      let url =
        trimslash (firstof [ imdsaddr; "http://169.254.169.254" ])
        ^ "/metadata/identity/oauth2/token?api-version=2018-02-01&resource="
        ^ Sigv4.uriescape azureresource
      in

      let res = fetchjson ~headers:[ ("Metadata", "true") ] "GET" url in
      let got = digtext res.jbody [ "access_token" ] in

      if 200 <> res.status || not (isset got) then
        fail "sekreto: azure: no token, no client credentials, and IMDS did not answer";

      renewat := renewtime (Json.odig res.jbody [ "expires_in" ]);
      Option.get got
    end
  in

  {
    lookup =
      (fun name ->
        if "" = vault then fail "sekreto: azure: no vault";

        (* ONLY an explicit scheme is a URL: a vault NAMED httpvault must
           still become https://httpvault.vault.azure.net. *)
        let vaulturl =
          if String.starts_with ~prefix:"http://" vault || String.starts_with ~prefix:"https://" vault
          then vault
          else "https://" ^ vault ^ ".vault.azure.net"
        in
        checkaddr vaulturl;

        if None = !livetoken || nowms () >= !renewat then livetoken := Some (login ());

        let url =
          trimslash vaulturl ^ "/secrets/" ^ flatname name "-" ^ "?api-version="
          ^ firstof [ apiversion; "7.4" ]
        in

        let res =
          fetchjson
            ~headers:[ ("authorization", "Bearer " ^ Option.value ~default:"" !livetoken) ]
            "GET" url
        in

        if 404 = res.status then None
        else if 200 <> res.status then
          fail ("sekreto: azure error: " ^ string_of_int res.status ^ ": " ^ bare url)
        else digtext res.jbody [ "value" ]);
    describe = (fun () -> "azuresecrets:" ^ vault);
  }

let plugin () : Defs.definition =
  providerplugin "azuresecrets" (fun spec ->
      azuresecrets_provider spec.vault spec.token spec.tenant spec.clientid spec.clientsecret
        spec.loginaddr spec.imdsaddr spec.apiversion)
