(* VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ocaml/plugins/infisical.ml) *)
(* Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* The `infisical` provider kind, as a voxgig/plugin definition.

   The Infisical API over HTTPS, with universal auth as the source of a
   token.

   A port of typescript/plugins/infisical.ts, which is canonical. *)

open Secret
open Provider
open Httpjson

(* Infisical.

   `api.token` reads the secret keyed `API_TOKEN` (Infisical's own
   convention is environment-style keys) at a secret path in one environment
   of a project. Auth is a token, or a universal-auth (machine identity)
   login. Its expiry field is `expiresIn`, camelCase, unlike everyone
   else's `expires_in`. *)
let infisical_provider (addr : string) (token : string) (clientid : string)
    (clientsecret : string) (project : string) (environment : string) (secretpath : string) :
    provider =
  let livetoken = ref None in
  let renewat = ref never in

  let login useaddr =
    if "" <> token then token
    else begin
      if "" = clientid || "" = clientsecret then
        fail "sekreto: infisical: no token and no client credentials";

      let body =
        Json.obj [ ("clientId", Json.str clientid); ("clientSecret", Json.str clientsecret) ]
      in

      let res =
        fetchjson
          ~headers:[ ("content-type", "application/json") ]
          ~body:(Json.stringify body) "POST"
          (useaddr ^ "/api/v1/auth/universal-auth/login")
      in

      let got = digtext res.jbody [ "accessToken" ] in
      if 200 <> res.status || not (isset got) then
        fail ("sekreto: infisical login failed: " ^ string_of_int res.status);

      renewat := renewtime (Json.odig res.jbody [ "expiresIn" ]);
      Option.get got
    end
  in

  {
    lookup =
      (fun name ->
        let useaddr = trimslash (firstof [ addr; "https://app.infisical.com" ]) in
        checkaddr useaddr;

        if "" = project || "" = environment then fail "sekreto: infisical: no project/environment";

        if None = !livetoken || nowms () >= !renewat then livetoken := Some (login useaddr);

        let url =
          useaddr ^ "/api/v3/secrets/raw/" ^ envkey name ^ "?workspaceId="
          ^ Sigv4.uriescape project ^ "&environment=" ^ Sigv4.uriescape environment
          ^ "&secretPath=" ^ Sigv4.uriescape (firstof [ secretpath; "/" ])
        in

        let res =
          fetchjson
            ~headers:[ ("authorization", "Bearer " ^ Option.value ~default:"" !livetoken) ]
            "GET" url
        in

        if 404 = res.status then None
        else if 200 <> res.status then fail ("sekreto: infisical error: " ^ string_of_int res.status)
        else digtext res.jbody [ "secret"; "secretValue" ]);
    describe = (fun () -> "infisical:" ^ project ^ "/" ^ environment);
  }

let plugin () : Defs.definition =
  providerplugin "infisical" (fun spec ->
      infisical_provider spec.addr spec.token spec.clientid spec.clientsecret spec.project
        spec.environment spec.secretpath)
