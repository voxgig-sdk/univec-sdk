(* VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ocaml/plugins/onepassword.ml) *)
(* Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* The `onepassword` provider kind, as a voxgig/plugin definition.

   1Password Connect over HTTPS.

   A port of typescript/plugins/onepassword.ts, which is canonical. *)

open Secret
open Provider
open Httpjson

(* 1Password, through a Connect server.

   The item titled `api.token` (titles KEEP THEIR DOTS), in the named vault.
   The value is the field with purpose PASSWORD, or the field labelled
   `value`. A vault that cannot be found is an ERROR, not a miss - config
   names it, so its absence is a broken store rather than a missing
   secret. *)
let onepassword_provider (addr : string) (token : string) (vault : string) : provider =
  let vaultid = ref None in

  let auth () = [ ("authorization", "Bearer " ^ token) ] in

  let resolvevault useaddr =
    if "" = vault then fail "sekreto: onepassword: no vault";

    let res = fetchjson ~headers:(auth ()) "GET" (useaddr ^ "/v1/vaults") in
    let list = Json.oasarr res.jbody in

    if 200 <> res.status || None = list then
      fail ("sekreto: onepassword error: " ^ string_of_int res.status ^ ": listing vaults");

    let entries = Option.get list in
    let found =
      List.find_opt
        (fun entry ->
          Some vault = Json.otext (Json.dig entry [ "id" ])
          || Some vault = Json.otext (Json.dig entry [ "name" ]))
        entries
    in

    match found with
    | Some entry -> Option.value ~default:"" (Json.otext (Json.dig entry [ "id" ]))
    | None -> fail ("sekreto: onepassword: no vault named " ^ vault)
  in

  {
    lookup =
      (fun name ->
        ignore (checkname name);

        let useaddr = trimslash addr in
        if "" = useaddr then fail "sekreto: onepassword: no addr";
        checkaddr useaddr;

        let id =
          match !vaultid with
          | Some found -> found
          | None ->
            let resolved = resolvevault useaddr in
            vaultid := Some resolved;
            resolved
        in

        let filter = Sigv4.uriescape ("title eq \"" ^ name ^ "\"") in
        let found =
          fetchjson ~headers:(auth ()) "GET" (useaddr ^ "/v1/vaults/" ^ id ^ "/items?filter=" ^ filter)
        in

        let items = Json.oasarr found.jbody in
        if 200 <> found.status || None = items then
          fail ("sekreto: onepassword error: " ^ string_of_int found.status ^ ": finding " ^ name);

        match Option.get items with
        (* No item with that title: a miss, and the chain carries on. *)
        | [] -> None
        | head :: _ ->
          let itemid = Option.value ~default:"" (Json.otext (Json.dig head [ "id" ])) in
          let item =
            fetchjson ~headers:(auth ()) "GET" (useaddr ^ "/v1/vaults/" ^ id ^ "/items/" ^ itemid)
          in

          if 200 <> item.status then
            fail ("sekreto: onepassword error: " ^ string_of_int item.status ^ ": reading " ^ name);

          let fields =
            match Json.oasarr (Json.odig item.jbody [ "fields" ]) with
            | Some list -> list
            | None -> []
          in

          (* Two full passes, in this order. *)
          let bypurpose =
            List.find_opt (fun field -> Some "PASSWORD" = Json.oasstr (Json.dig field [ "purpose" ])) fields
          in

          (match bypurpose with
          | Some field -> Json.otext (Json.dig field [ "value" ])
          | None -> (
            match
              List.find_opt (fun field -> Some "value" = Json.oasstr (Json.dig field [ "label" ])) fields
            with
            | Some field -> Json.otext (Json.dig field [ "value" ])
            | None -> None)));
    describe = (fun () -> "onepassword:" ^ vault);
  }

let plugin () : Defs.definition =
  providerplugin "onepassword" (fun spec ->
      onepassword_provider spec.addr spec.token spec.vault)
