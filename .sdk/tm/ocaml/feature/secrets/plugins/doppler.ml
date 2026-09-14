(* VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ocaml/plugins/doppler.ml) *)
(* Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* The `doppler` provider kind, as a voxgig/plugin definition.

   The Doppler API over HTTPS.

   A port of typescript/plugins/doppler.ts, which is canonical. *)

open Secret
open Provider
open Httpjson

(* Doppler.

   The whole config is downloaded ONCE - Doppler's own bulk endpoint - and
   answered from memory, like a remote .env: `api.token` is the `API_TOKEN`
   entry. A service token is config-scoped, so project and config are only
   needed with broader tokens. A failed load caches nothing, so it retries.

   The `prefix` option is deliberately not consulted by this kind. *)
let doppler_provider (token : string) (project : string) (config : string) (addr : string) :
    provider =
  let values = ref None in

  let load () =
    match !values with
    | Some loaded -> loaded
    | None ->
      let useaddr = trimslash (firstof [ addr; "https://api.doppler.com" ]) in
      checkaddr useaddr;

      let url = ref (useaddr ^ "/v3/configs/config/secrets/download?format=json") in
      if "" <> project then url := !url ^ "&project=" ^ Sigv4.uriescape project;
      if "" <> config then url := !url ^ "&config=" ^ Sigv4.uriescape config;

      let res = fetchjson ~headers:[ ("authorization", "Bearer " ^ token) ] "GET" !url in
      let body = Json.oasobj res.jbody in

      if 200 <> res.status || None = body then
        fail ("sekreto: doppler error: " ^ string_of_int res.status);

      let loaded =
        List.filter_map
          (fun (key, value) -> match Json.text value with Some text -> Some (key, text) | None -> None)
          (Option.get body)
      in

      values := Some loaded;
      loaded
  in

  {
    lookup = (fun name -> List.assoc_opt (envkey name) (load ()));
    describe =
      (fun () -> if "" = project then "doppler" else "doppler:" ^ project ^ "/" ^ config);
  }

let plugin () : Defs.definition =
  providerplugin "doppler" (fun spec ->
      doppler_provider spec.token spec.project spec.config spec.addr)
