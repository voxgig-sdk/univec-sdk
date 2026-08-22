(* Custom utility overrides (mirrors tm/rust custom_utility_test): caller-
 * supplied callables in options.utility land on utility.custom, reachable via
 * the client's utility bundle. *)

open Voxgig_struct
open Sdk_types
open Sdk_helpers
open Testutil

let utils = [
  ("auth", "AUTH"); ("body", "BODY"); ("contextify", "CONTEXTIFY"); ("done", "DONE");
  ("error", "ERROR"); ("findparam", "FINDPARAM"); ("fullurl", "FULLURL"); ("headers", "HEADERS");
  ("method", "METHOD"); ("operator", "OPERATOR"); ("params", "PARAMS"); ("query", "QUERY");
  ("reqform", "REQFORM"); ("request", "REQUEST"); ("resbasic", "RESBASIC"); ("resbody", "RESBODY");
  ("resform", "RESFORM"); ("resheaders", "RESHEADERS"); ("response", "RESPONSE"); ("result", "RESULT");
  ("spec", "SPEC") ]

let () =
  test "custom_utility.basic" (fun () ->
      let utility_opts = empty_map () in
      List.iter (fun (key, tag) ->
          setp utility_opts key (vfunc1 (fun _ -> jo [("util", Str tag)]))) utils;
      let client =
        Sdk_client.test_with Noval (jo [("apikey", Str "APIKEY01"); ("utility", utility_opts)]) in
      let u = client.cl_utility in
      List.iter (fun (key, tag) ->
          let f = getp u.u_custom key in
          check (key ^ " exists") (is_callable f);
          let out = call_vfn f Noval in
          check_vstr (key ^ " tag") (getp out "util") tag) utils)
