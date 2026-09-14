(* Behavioural tests for the secrets feature (vendored @voxgig/sekreto).
 *
 * The contract under test: the `apikey` OPTION keeps its exact old meaning
 * and always wins, because the feature seats it FIRST in the provider chain
 * (a `memory` store named `options`) - explicit-beats-lookup falls out of
 * sekreto's first-hit rule rather than from special-case logic. With the
 * feature inactive nothing changes at all. With it active and the option
 * unset, the chain supplies the credential instead.
 *
 * THE SHAPE OF EVERY FAIL-CLOSED CASE HERE, and why. A test that passes
 * whether or not the thing it names is present is worthless, so:
 *   - the client is LIVE (Sdk_client.make), so `options.system.fetch` really
 *     is the transport and the feature's wrapper sits above it - never the
 *     test-mode mock, which replaces the fetcher and hides the seam;
 *   - every assertion reads the authorization header the RECORDER received,
 *     never the options map, which this feature never writes;
 *   - a refusal must carry the PROVIDER'S OWN message (sekreto's wording),
 *     not any error;
 *   - beside every refusal is a CONTROL leg: the same construction with a
 *     working provider reaches the same recorder exactly once - so a zero
 *     on the refused leg means REFUSED, not UNWIRED.
 * Delete the gate in feature/secrets_feature.ml and these go RED.
 *
 * This file lives in the test/feature/ container on purpose: `target add`
 * trims it, along with the feature source and the vendored trees, for a
 * project whose model does not select `secrets`; feature/secrets/feature.mk lists it, so
 * it is linked into run_sdk_test whenever the feature is. It prints
 * `feature.secrets: ran N check(s)` from EXECUTIONS, which the generator's
 * own lane requires - a suite trimmed to nothing cannot pass by exiting
 * zero. *)

open Voxgig_struct
open Sdk_types
open Sdk_helpers
open Testutil

(* Executed-case count, for the line the lane reads. *)
let ran = ref 0
let test (name : string) (f : unit -> unit) : unit =
  incr ran;
  Testutil.test ("secrets." ^ name) f

let envprefix = "PROJECTENV_TEST_SECRETS_"

(* ---------------------------------------------------------------------- *)
(* the recorder: a system.fetch that remembers what reached it            *)
(* ---------------------------------------------------------------------- *)

let ok200 (data : value) : value =
  jo [("status", Num 200.); ("statusText", Str "OK"); ("headers", empty_map ());
      ("body", Str "not-used"); ("json", json_thunk data)]

let status_res (status : int) (data : value) : value =
  jo [("status", vint_of status); ("statusText", Str (if status < 400 then "OK" else "ERR"));
      ("headers", empty_map ()); ("body", Str "not-used"); ("json", json_thunk data)]

type recorder = {
  calls : value list ref;
  (* (call number, url, fetchdef) -> the transport-shaped response *)
  mutable reply : (int -> string -> value -> value) option;
}

let is_token (url : string) : bool =
  let suffix = "/auth/token" in
  let lu = String.length url and ls = String.length suffix in
  lu >= ls && String.sub url (lu - ls) ls = suffix

let recorder () : recorder * value =
  let r = { calls = ref []; reply = None } in
  let fetch = Func (fun _ args _ _ ->
      let (url, fd) = match args with
        | List l -> (match !l with
            | Str u :: fd :: _ -> (u, fd)
            | Str u :: [] -> (u, Noval)
            | _ -> ("", Noval))
        | _ -> ("", Noval) in
      r.calls := !(r.calls) @ [jo [("url", Str url); ("fetchdef", fd)]];
      match r.reply with
      | Some f -> f (List.length !(r.calls)) url fd
      | None -> ok200 (jo [("id", Str "r01")])) in
  (r, fetch)

(* The API calls (not the token endpoint) the recorder saw, in order. *)
let api_calls (r : recorder) : value list =
  List.filter (fun c -> not (is_token (match getp c "url" with Str u -> u | _ -> ""))) !(r.calls)

let token_calls (r : recorder) : value list =
  List.filter (fun c -> is_token (match getp c "url" with Str u -> u | _ -> "")) !(r.calls)

(* The authorization header the i-th API call carried, or Noval. *)
let auth_of (r : recorder) (i : int) : value =
  match List.nth_opt (api_calls r) i with
  | Some c -> (match getp (getp c "fetchdef") "headers" with
      | Map _ as h -> Sdk_features.header_ci h "authorization"
      | _ -> Noval)
  | None -> Noval

(* The Authorization header carries the SPEC's credential prefix, which a
 * TEMPLATE cannot know - so assert on the CREDENTIAL and let the prefix be
 * whatever this SDK's API declares. *)
let credential_is (header : value) (token : string) : bool =
  match header with
  | Str s -> s = token || Sdk_features.ends_with s (" " ^ token)
  | _ -> false

let absent (header : value) : bool = is_nullish header

(* ---------------------------------------------------------------------- *)
(* clients and paths                                                      *)
(* ---------------------------------------------------------------------- *)

(* A LIVE client with the secrets feature active and the recorder as its
 * transport. `sdkopts` are extra top-level options (apikey, auth, name...). *)
let live ?(sdkopts : (string * value) list = []) ?(base = "http://secrets.test/api")
    (fetch : value) (fopts : (string * value) list) : sdk_client =
  Sdk_client.make (jo ([
      ("base", Str base);
      ("system", jo [("fetch", fetch)]);
      ("feature", jo [("secrets", jo (("active", Bool true) :: fopts))]);
    ] @ sdkopts))

(* The same construction with the feature declared INACTIVE. *)
let inactive ?(sdkopts : (string * value) list = []) (fetch : value) : sdk_client =
  Sdk_client.make (jo ([
      ("base", Str "http://secrets.test/api");
      ("system", jo [("fetch", fetch)]);
      ("feature", jo [("secrets", jo [("active", Bool false)])]);
    ] @ sdkopts))

let direct (client : sdk_client) : value =
  Sdk_client.direct client (jo [("path", Str "/thing"); ("method", Str "GET")])

let graphql (client : sdk_client) : value =
  Sdk_client.graphql client "{ thing { id } }" Noval Noval

let res_ok (res : value) : bool = getp res "ok" = Bool true

let res_err (res : value) : string =
  match getp res "err" with
  | Str s -> s
  | Map _ as m -> (match getp m "message" with Str s -> s | _ -> stringify m)
  | _ -> ""

let contains (hay : string) (needle : string) : bool =
  let lh = String.length hay and ln = String.length needle in
  let rec go i = i + ln <= lh && (String.sub hay i ln = needle || go (i + 1)) in
  ln = 0 || go 0

(* THE ENTITY PIPELINE, through the entities this SDK generated. This file
 * is a template and knows no project's entity names, so they are read from
 * the generated config and reached through Sdk_client.entity (the by-name
 * accessor). Real ops are driven until one reaches the recorder or the
 * chain refuses one; an op the API does not define fails BEFORE the
 * transport, which is why several may need driving. *)
let entity_names () : string list =
  match getp (Sdk_config.make_config ()) "entity" with
  | Map _ as m -> keysof m
  | _ -> []

(* Drive ops until one request reached the recorder. *)
let drive_entity (client : sdk_client) (r : recorder) : (unit, string) Stdlib.result =
  let before = List.length (api_calls r) in
  let out = ref (Error "") in
  (* A refused op raises before the recorder sees anything; a working one
   * reaches it. Either way the first op that consulted the chain settles
   * it, so ops are driven until the recorder grew or an op reported. *)
  let rec go names =
    match names with
    | [] -> ()
    | name :: rest ->
      (match Sdk_client.entity client name Noval with
       | None -> go rest
       | Some ent ->
         let rec ops = function
           | [] -> go rest
           | opname :: more ->
             (match (match opname with
                  | "list" -> ignore (ent.e_list (empty_map ()) Noval)
                  | _ -> ignore (ent.e_load (jo [("id", Str "id01")]) Noval)) with
              | () ->
                out := Ok ();
                if before < List.length (api_calls r) then () else ops more
              | exception Sdk_error_exc e ->
                (* An op the entity does not define fails before the chain
                 * is consulted: keep going. Anything else is the answer. *)
                if e.err_code = "unsupported_op" then ops more
                else (out := Error e.err_msg)
              | exception e -> out := Error (Printexc.to_string e))
         in
         ops ["list"; "load"])
  in
  go (entity_names ());
  !out

(* Custom (Func) providers: asked the secret name, answer a string, a miss
 * (Null) or raise. `asked` counts lookups. *)
let custom (answer : int -> value) : value * int ref =
  let asked = ref 0 in
  let fn = vfunc1 (fun _name -> incr asked; answer !asked) in
  (fn, asked)

let working (v : string) : value = fst (custom (fun _ -> Str v))

let broken (message : string) : value =
  vfunc1 (fun _ -> Secret.fail message)

let memory ?(name = "options2") (values : (string * value) list) : value =
  jo [("kind", Str "memory"); ("name", Str name); ("values", jo values)]

(* ---------------------------------------------------------------------- *)
(* inactive                                                               *)
(* ---------------------------------------------------------------------- *)

let () =
  test "inactive.apikey_option_behaves_as_before" (fun () ->
      let (r, fetch) = recorder () in
      let client = inactive ~sdkopts:[("apikey", Str "OPTKEY01")] fetch in
      check "ok" (res_ok (direct client));
      check_int "one call" (List.length (api_calls r)) 1;
      check "carries OPTKEY01" (credential_is (auth_of r 0) "OPTKEY01"));

  test "inactive.no_apikey_no_header" (fun () ->
      let (r, fetch) = recorder () in
      let client = inactive fetch in
      check "ok" (res_ok (direct client));
      check "no header" (absent (auth_of r 0)));

  (* ---------------------------------------------------------------------- *)
  (* the chain                                                              *)
  (* ---------------------------------------------------------------------- *)

  Unix.putenv (envprefix ^ "APIKEY") "ENVKEY01";

  test "chain.apikey_option_still_wins" (fun () ->
      let (r, fetch) = recorder () in
      let client = live ~sdkopts:[("apikey", Str "OPTKEY01")] fetch
          [("providers", ja [jo [("kind", Str "env"); ("prefix", Str envprefix)]])] in
      check "ok" (res_ok (direct client));
      check "carries OPTKEY01, not ENVKEY01" (credential_is (auth_of r 0) "OPTKEY01"));

  test "chain.omitted_apikey_defers_to_the_chain" (fun () ->
      let (r, fetch) = recorder () in
      let client = live fetch
          [("providers", ja [jo [("kind", Str "env"); ("prefix", Str envprefix)]])] in
      check "ok" (res_ok (direct client));
      check "carries ENVKEY01" (credential_is (auth_of r 0) "ENVKEY01"));

  test "chain.explicitly_empty_apikey_defers_to_the_chain" (fun () ->
      let (r, fetch) = recorder () in
      let client = live ~sdkopts:[("apikey", Str "")] fetch
          [("providers", ja [jo [("kind", Str "env"); ("prefix", Str envprefix)]])] in
      check "ok" (res_ok (direct client));
      check "carries ENVKEY01" (credential_is (auth_of r 0) "ENVKEY01"));

  test "chain.custom_provider_accepted_verbatim" (fun () ->
      let (r, fetch) = recorder () in
      let names = ref [] in
      let fn = vfunc1 (fun name -> names := !names @ [name]; Str "CUSTOM01") in
      let client = live fetch [("providers", ja [fn])] in
      check "ok" (res_ok (direct client));
      check "carries CUSTOM01" (credential_is (auth_of r 0) "CUSTOM01");
      check "asked for the configured secret name" (!names = [Str "apikey"]));

  test "chain.custom_provider_asked_for_the_configured_name" (fun () ->
      let (r, fetch) = recorder () in
      let names = ref [] in
      let fn = vfunc1 (fun name -> names := !names @ [name]; Str "CUSTOM02") in
      let client = live fetch [("providers", ja [fn]); ("name", Str "api.token")] in
      check "ok" (res_ok (direct client));
      check "carries CUSTOM02" (credential_is (auth_of r 0) "CUSTOM02");
      check "asked api.token" (!names = [Str "api.token"]));

  test "chain.miss_everywhere_leaves_the_header_off" (fun () ->
      let (r, fetch) = recorder () in
      let (fn, asked) = custom (fun _ -> Null) in
      let client = live fetch [("providers", ja [fn])] in
      check "ok" (res_ok (direct client));
      check_int "one call" (List.length (api_calls r)) 1;
      check "no header" (absent (auth_of r 0));
      check_int "the chain was asked" !asked 1);

  test "chain.miss_falls_through_to_the_next_provider" (fun () ->
      let (r, fetch) = recorder () in
      let (fn, _) = custom (fun _ -> Null) in
      let client = live fetch [("providers", ja [fn; memory [("APIKEY", Str "MEM01")]])] in
      check "ok" (res_ok (direct client));
      check "carries MEM01" (credential_is (auth_of r 0) "MEM01"));

  (* ---------------------------------------------------------------------- *)
  (* fail closed: a provider ERROR never degrades into an unauthenticated  *)
  (* request, on every wire path                                           *)
  (* ---------------------------------------------------------------------- *)

  test "error.direct_is_refused_with_the_providers_message" (fun () ->
      let (r, fetch) = recorder () in
      let client = live fetch [("providers", ja [broken "vault unreachable"])] in
      let res = direct client in
      check "refused" (not (res_ok res));
      check ("carries the provider's own message: " ^ res_err res)
        (contains (res_err res) "vault unreachable");
      check_int "nothing reached the wire" (List.length (api_calls r)) 0;
      (* CONTROL *)
      let (r2, fetch2) = recorder () in
      let ok = live fetch2 [("providers", ja [working "CUSTOM01"])] in
      check "control: the working chain succeeds" (res_ok (direct ok));
      check_int "control: reached the wire once" (List.length (api_calls r2)) 1;
      check "control: with the credential" (credential_is (auth_of r2 0) "CUSTOM01"));

  test "error.graphql_is_refused_with_the_providers_message" (fun () ->
      let (r, fetch) = recorder () in
      let client = live fetch [("providers", ja [broken "vault unreachable"])] in
      let res = graphql client in
      check "refused" (not (res_ok res));
      check ("carries the provider's own message: " ^ res_err res)
        (contains (res_err res) "vault unreachable");
      check_int "graphql sent nothing" (List.length (api_calls r)) 0;
      let (r2, fetch2) = recorder () in
      let ok = live fetch2 [("providers", ja [working "CUSTOM01"])] in
      check "control: graphql with a working chain succeeds" (res_ok (graphql ok));
      check_int "control: graphql reached the wire once" (List.length (api_calls r2)) 1;
      check "control: graphql carried the credential" (credential_is (auth_of r2 0) "CUSTOM01"));

  test "error.entity_op_is_refused_with_the_providers_message" (fun () ->
      let (r, fetch) = recorder () in
      let client = live fetch [("providers", ja [broken "vault unreachable"])] in
      (match drive_entity client r with
       | Ok () -> failwith "entity: the op succeeded through a broken chain"
       | Error msg ->
         check ("entity: carries the provider's own message: " ^ msg)
           (contains msg "vault unreachable"));
      check_int "entity: nothing reached the transport" (List.length (api_calls r)) 0;
      let (r2, fetch2) = recorder () in
      let ok = live fetch2 [("providers", ja [working "CUSTOM01"])] in
      (match drive_entity ok r2 with
       | Ok () -> ()
       | Error msg -> failwith ("control: the entity op failed: " ^ msg));
      check_int "control: the entity op reached the transport once" (List.length (api_calls r2)) 1;
      check "control: the entity op carried the credential" (credential_is (auth_of r2 0) "CUSTOM01"));

  test "error.fails_even_though_a_later_provider_has_the_secret" (fun () ->
      let (r, fetch) = recorder () in
      let client = live fetch
          [("providers", ja [broken "vault unreachable"; memory [("APIKEY", Str "MEM01")]])] in
      let res = direct client in
      check "refused" (not (res_ok res));
      check "the provider's message" (contains (res_err res) "vault unreachable");
      check_int "nothing reached the wire" (List.length (api_calls r)) 0);

  test "error.a_broken_store_does_not_poison_the_client" (fun () ->
      let (r, fetch) = recorder () in
      let (fn, _) = custom (fun n -> if n = 1 then Secret.fail "vault unreachable" else Str "LATE01") in
      let client = live fetch [("providers", ja [fn])] in
      check "first op refused" (not (res_ok (direct client)));
      check_int "nothing sent" (List.length (api_calls r)) 0;
      check "second op succeeds" (res_ok (direct client));
      check_int "one call" (List.length (api_calls r)) 1;
      check "carries LATE01" (credential_is (auth_of r 0) "LATE01"));

  test "error.a_builtin_that_cannot_read_is_an_error_not_a_miss" (fun () ->
      (* dotenv pointed at a DIRECTORY: sekreto's own wording, from the
       * vendored built-in, and nothing on the wire. *)
      let (r, fetch) = recorder () in
      let dir = Filename.get_temp_dir_name () in
      let client = live fetch
          [("providers", ja [jo [("kind", Str "dotenv"); ("file", Str dir)];
                            memory [("APIKEY", Str "MEM01")]])] in
      let res = direct client in
      check "refused" (not (res_ok res));
      check ("sekreto's message: " ^ res_err res)
        (contains (res_err res) "sekreto: dotenv provider cannot read");
      check_int "nothing reached the wire" (List.length (api_calls r)) 0);

  (* ---------------------------------------------------------------------- *)
  (* the init-failure gate: a chain that cannot be built refuses every     *)
  (* request; a malformed entry is refused, never dropped                  *)
  (* ---------------------------------------------------------------------- *)

  test "gate.a_bare_kind_name_is_refused_not_dropped" (fun () ->
      let (r, fetch) = recorder () in
      let client = live fetch
          [("providers", ja [Str "hashicorp"; memory [("APIKEY", Str "MEM01")]])] in
      let res = direct client in
      check "refused" (not (res_ok res));
      check ("sekreto's wording: " ^ res_err res)
        (contains (res_err res) "sekreto: not a provider or a provider spec"
         && contains (res_err res) "hashicorp");
      check_int "nothing reached the wire" (List.length (api_calls r)) 0);

  test "gate.a_number_is_refused_not_dropped" (fun () ->
      let (r, fetch) = recorder () in
      let client = live fetch [("providers", ja [Num 42.; memory [("APIKEY", Str "MEM01")]])] in
      let res = direct client in
      check "refused" (not (res_ok res));
      check "sekreto's wording" (contains (res_err res) "not a provider or a provider spec");
      check_int "nothing reached the wire" (List.length (api_calls r)) 0);

  test "gate.a_null_hole_does_not_shorten_the_chain" (fun () ->
      let (r, fetch) = recorder () in
      let client = live fetch [("providers", ja [Null; memory [("APIKEY", Str "MEM01")]])] in
      let res = direct client in
      check "refused" (not (res_ok res));
      check "sekreto's wording" (contains (res_err res) "not a provider or a provider spec");
      check_int "nothing reached the wire" (List.length (api_calls r)) 0);

  test "gate.an_unknown_kind_is_refused_with_sekretos_message" (fun () ->
      let (r, fetch) = recorder () in
      let client = live fetch [("providers", ja [jo [("kind", Str "nosuchkind")]])] in
      let res = direct client in
      check "refused" (not (res_ok res));
      check ("sekreto's message: " ^ res_err res)
        (contains (res_err res) "sekreto: unknown provider kind: nosuchkind");
      check_int "nothing reached the wire" (List.length (api_calls r)) 0);

  test "gate.an_invalid_secret_name_is_refused_not_skipped" (fun () ->
      let (r, fetch) = recorder () in
      let client = live ~sdkopts:[("apikey", Str "OPTKEY01")] fetch
          [("providers", ja [working "CUSTOM01"]); ("name", Str "not a name!")] in
      let res = direct client in
      check "refused" (not (res_ok res));
      check ("sekreto's message: " ^ res_err res) (contains (res_err res) "sekreto:");
      check_int "nothing reached the wire" (List.length (api_calls r)) 0);

  test "gate.plugin_kinds_are_the_models_choice" (fun () ->
      (* The vocabulary really is the model's: the definitions Config_ocaml
       * selected, read back through the generated accessor. A plugin kind
       * either resolves through its vendored module (here: refused by the
       * store's own unreachable-address error, since nothing listens) or,
       * when its group is off, is refused as "not passed in" - sekreto's
       * own message in both cases, and nothing on the wire in either. *)
      let defs = Sdk_config.feature_plugins "secrets" in
      Printf.printf "secrets: %d plugin definition(s) selected by the model\n" (List.length defs);
      let (r, fetch) = recorder () in
      let client = live fetch
          [("providers", ja [jo [("kind", Str "hashicorp"); ("addr", Str "http://127.0.0.1:1");
                                 ("token", Str "t")]])] in
      let res = direct client in
      check "refused" (not (res_ok res));
      let msg = res_err res in
      Printf.printf "secrets: hashicorp kind -> %s\n" msg;
      check ("sekreto's message: " ^ msg)
        (contains msg "is a sekreto plugin, not built in" || contains msg "sekreto: cannot reach");
      check_int "nothing reached the wire" (List.length (api_calls r)) 0);

  (* ---------------------------------------------------------------------- *)
  (* auth suppression                                                       *)
  (* ---------------------------------------------------------------------- *)

  test "auth.null_suppresses_the_credential_chain_or_no_chain" (fun () ->
      let (r, fetch) = recorder () in
      let client = live ~sdkopts:[("auth", Null)] fetch
          [("providers", ja [jo [("kind", Str "env"); ("prefix", Str envprefix)]])] in
      check "ok" (res_ok (direct client));
      check_int "one call" (List.length (api_calls r)) 1;
      check "no header, though the chain resolved" (absent (auth_of r 0));
      (* The suppression survives option validation as a present null. *)
      check "options.auth survives as a present null"
        (getprop_raw client.cl_options "auth" = Null));

  test "auth.null_suppresses_an_explicit_apikey_too" (fun () ->
      let (r, fetch) = recorder () in
      let client = live ~sdkopts:[("auth", Null); ("apikey", Str "OPTKEY01")] fetch
          [("providers", ja [working "CUSTOM01"])] in
      check "ok" (res_ok (direct client));
      check "no header" (absent (auth_of r 0)));

  test "auth.null_suppresses_on_the_entity_path" (fun () ->
      let (r, fetch) = recorder () in
      let client = live ~sdkopts:[("auth", Null)] fetch [("providers", ja [working "CUSTOM01"])] in
      (match drive_entity client r with
       | Ok () -> ()
       | Error msg -> failwith ("entity op failed: " ^ msg));
      check_int "reached the transport once" (List.length (api_calls r)) 1;
      check "no header" (absent (auth_of r 0)));

  test "entity.carries_the_chain_resolved_credential" (fun () ->
      let (r, fetch) = recorder () in
      let client = live fetch [("providers", ja [jo [("kind", Str "env"); ("prefix", Str envprefix)]])] in
      (match drive_entity client r with
       | Ok () -> ()
       | Error msg -> failwith ("entity op failed: " ^ msg));
      check_int "reached the transport once" (List.length (api_calls r)) 1;
      check "carries ENVKEY01" (credential_is (auth_of r 0) "ENVKEY01"));

  (* ---------------------------------------------------------------------- *)
  (* cache                                                                  *)
  (* ---------------------------------------------------------------------- *)

  test "cache.caches_the_resolved_credential_by_default" (fun () ->
      let (r, fetch) = recorder () in
      let (fn, asked) = custom (fun _ -> Str "C01") in
      let client = live fetch [("providers", ja [fn])] in
      check "ok 1" (res_ok (direct client));
      check "ok 2" (res_ok (direct client));
      check_int "two calls" (List.length (api_calls r)) 2;
      check_int "asked once" !asked 1;
      check "both carry C01" (credential_is (auth_of r 0) "C01" && credential_is (auth_of r 1) "C01"));

  test "cache.false_asks_the_chain_once_per_request" (fun () ->
      let (r, fetch) = recorder () in
      let (fn, asked) = custom (fun _ -> Str "C01") in
      let client = live fetch [("providers", ja [fn]); ("cache", Bool false)] in
      check "ok 1" (res_ok (direct client));
      check "ok 2" (res_ok (direct client));
      check_int "two calls" (List.length (api_calls r)) 2;
      check_int "asked twice" !asked 2);

  test "cache.an_uncached_miss_after_a_hit_retracts_the_credential" (fun () ->
      let (r, fetch) = recorder () in
      let (fn, _) = custom (fun n -> if n = 1 then Str "C01" else Null) in
      let client = live fetch [("providers", ja [fn]); ("cache", Bool false)] in
      check "ok 1" (res_ok (direct client));
      check "first carries C01" (credential_is (auth_of r 0) "C01");
      check "ok 2" (res_ok (direct client));
      check "second carries nothing: the revoked value must not keep going out"
        (absent (auth_of r 1)));

  (* ---------------------------------------------------------------------- *)
  (* the access-token exchange                                              *)
  (* ---------------------------------------------------------------------- *)

  let xchg (extra : (string * value) list) : (string * value) =
    ("exchange", jo (("active", Bool true) :: extra)) in
  let refresh_chain (v : string) : (string * value) =
    ("providers", ja [memory ~name:"refresh" [("REFRESH_TOKEN", Str v)]]) in

  (* A token endpoint answering ACCESS<k> to the k-th purchase; the API
   * answers `api` (status by the token it was handed). *)
  let token_server (r : recorder) (api : string -> int) : unit =
    r.reply <- Some (fun _n url fd ->
        if is_token url then
          ok200 (jo [("access_token", Str ("ACCESS" ^ string_of_int (List.length (token_calls r))))])
        else
          let token = match getp fd "headers" with
            | Map _ as h -> (match Sdk_features.header_ci h "authorization" with Str s -> s | _ -> "")
            | _ -> "" in
          status_res (api token) (jo [("id", Str "r01")])) in

  let body_of (call : value) : value =
    match getp (getp call "fetchdef") "body" with
    | Str s -> (try Sdk_json.json_read s with _ -> Noval)
    | b -> b in

  test "exchange.buys_an_access_token_with_the_resolved_refresh_token" (fun () ->
      let (r, fetch) = recorder () in
      token_server r (fun _ -> 200);
      let client = live fetch [refresh_chain "R1"; ("name", Str "refresh_token"); xchg []] in
      check "ok" (res_ok (direct client));
      check_int "one purchase" (List.length (token_calls r)) 1;
      check_int "one API call" (List.length (api_calls r)) 1;
      check "the API call carries the bought token" (credential_is (auth_of r 0) "ACCESS1");
      let tc = List.hd (token_calls r) in
      check "POSTed to base + exchange.path"
        ((match getp tc "url" with Str u -> u | _ -> "") = "http://secrets.test/api/auth/token");
      check "the body is JSON-marshalled with the refresh token"
        (getp (body_of tc) "refresh_token" = Str "R1"));

  test "exchange.body_is_marshalled_not_concatenated" (fun () ->
      let (r, fetch) = recorder () in
      token_server r (fun _ -> 200);
      let quoted = "R\"1\\x" in
      let client = live fetch [refresh_chain quoted; ("name", Str "refresh_token"); xchg []] in
      check "ok" (res_ok (direct client));
      check "a refresh token carrying a quote and a backslash survives"
        (getp (body_of (List.hd (token_calls r))) "refresh_token" = Str quoted));

  test "exchange.a_spent_token_is_repurchased_and_retried_once" (fun () ->
      let (r, fetch) = recorder () in
      token_server r (fun token -> if credential_is (Str token) "ACCESS1" then 401 else 200);
      let client = live fetch [refresh_chain "R1"; ("name", Str "refresh_token"); xchg []] in
      check "ok" (res_ok (direct client));
      check_int "two purchases" (List.length (token_calls r)) 2;
      check_int "two API calls: the refusal and the retry" (List.length (api_calls r)) 2;
      check "the retry carries the fresh token" (credential_is (auth_of r 1) "ACCESS2"));

  test "exchange.a_second_refusal_surfaces_rather_than_spinning" (fun () ->
      let (r, fetch) = recorder () in
      token_server r (fun _ -> 401);
      let client = live fetch [refresh_chain "R1"; ("name", Str "refresh_token"); xchg []] in
      let res = direct client in
      check "the refusal surfaces" (not (res_ok res));
      check_vnum "with the API's status" (getp res "status") 401.;
      check_int "exactly two API calls" (List.length (api_calls r)) 2;
      check_int "exactly two purchases" (List.length (token_calls r)) 2);

  test "exchange.retries_zero_never_repurchases" (fun () ->
      let (r, fetch) = recorder () in
      token_server r (fun _ -> 401);
      let client = live fetch [refresh_chain "R1"; ("name", Str "refresh_token"); xchg [("retries", Num 0.)]] in
      check "refused" (not (res_ok (direct client)));
      check_int "one API call" (List.length (api_calls r)) 1;
      check_int "one purchase" (List.length (token_calls r)) 1);

  test "exchange.refresh_option_seats_first_as_the_explicit_credential" (fun () ->
      let (r, fetch) = recorder () in
      token_server r (fun _ -> 200);
      let client = live fetch [refresh_chain "R2"; ("name", Str "refresh_token"); xchg [("refresh", Str "R1")]] in
      check "ok" (res_ok (direct client));
      check "the explicit refresh token was spent, not the chain's"
        (getp (body_of (List.hd (token_calls r))) "refresh_token" = Str "R1"));

  test "exchange.a_held_apikey_is_spent_before_anything_is_bought" (fun () ->
      let (r, fetch) = recorder () in
      token_server r (fun _ -> 200);
      let client = live ~sdkopts:[("apikey", Str "HELD01")] fetch
          [refresh_chain "R1"; ("name", Str "refresh_token"); xchg []] in
      check "ok" (res_ok (direct client));
      check_int "nothing bought" (List.length (token_calls r)) 0;
      check "the held access token went out" (credential_is (auth_of r 0) "HELD01"));

  test "exchange.no_refresh_token_anywhere_is_a_refusal_with_the_features_message" (fun () ->
      let (r, fetch) = recorder () in
      token_server r (fun _ -> 200);
      let client = live fetch [("providers", ja []); ("name", Str "refresh_token"); xchg []] in
      let res = direct client in
      check "refused" (not (res_ok res));
      check ("the feature's message: " ^ res_err res) (contains (res_err res) "secrets: no refresh token");
      check_int "nothing reached the wire" (List.length (api_calls r)) 0;
      check_int "nothing bought" (List.length (token_calls r)) 0);

  test "exchange.without_a_transport_is_a_named_refusal" (fun () ->
      (* This SDK's core bundles no HTTP client. With no options.system.fetch
       * the purchase either has the vendored sekreto client (a plugin
       * group needing one is active: it dials the loopback port nothing
       * listens on and says so) or nothing at all (and says so). Never a
       * silent unauthenticated send. *)
      let client = Sdk_client.make (jo [
          ("base", Str "http://127.0.0.1:1");
          ("feature", jo [("secrets", jo [("active", Bool true); refresh_chain "R1";
                                          ("name", Str "refresh_token"); xchg []])])]) in
      let res = direct client in
      check "refused" (not (res_ok res));
      let msg = res_err res in
      Printf.printf "secrets: exchange without system.fetch -> %s\n" msg;
      check ("a named refusal: " ^ msg)
        (contains msg "secrets: the token exchange has no HTTP transport"
         || contains msg "sekreto: cannot reach"));

  test "exchange.test_mode_buys_nothing" (fun () ->
      (* A non-live client: the credential becomes the deterministic
       * `test-<response>` and no purchase is attempted. Observed through
       * ctrl.explain, which records the live fetchdef whose headers map
       * the wrapper rewrites in place. *)
      let client = Sdk_client.test_with Noval (jo [
          ("feature", jo [("secrets", jo [("active", Bool true); refresh_chain "R1";
                                          ("name", Str "refresh_token"); xchg []])])]) in
      let explain = empty_map () in
      let seen = ref false in
      List.iter (fun name ->
          if not !seen then
            match Sdk_client.entity client name Noval with
            | None -> ()
            | Some ent ->
              (try ignore (ent.e_list (empty_map ()) (jo [("explain", explain)])) with _ -> ());
              (match getpath_s explain "fetchdef.headers" with
               | Map _ -> seen := true
               | _ -> (try ignore (ent.e_load (jo [("id", Str "id01")]) (jo [("explain", explain)])) with _ -> ());
                 (match getpath_s explain "fetchdef.headers" with Map _ -> seen := true | _ -> ())))
        (entity_names ());
      check "an entity op recorded its fetchdef" !seen;
      let header = match getpath_s explain "fetchdef.headers" with
        | Map _ as h -> Sdk_features.header_ci h "authorization"
        | _ -> Noval in
      check ("carries the deterministic test token: " ^ stringify header)
        (credential_is header "test-access_token");
      check_vnum "one (fake) purchase, tracked" (getp (track_get client "secrets") "buys") 1.);

  ()

(* Printed from EXECUTIONS, for the generator's lane. *)
let () = Printf.printf "feature.secrets: ran %d check(s)\n" !ran
