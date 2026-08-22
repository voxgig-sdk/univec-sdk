(* Direct unit tests for the operation-pipeline utilities (mirrors the py
 * test_pipeline). Drives the error/edge branches a happy-path op never
 * reaches. API-agnostic: everything is reached through the client utility. *)

open Voxgig_struct
open Sdk_types
open Sdk_helpers
open Sdk_runtime
open Testutil

let client () = Sdk_client.test ()

let mk_ctx ?(ctrl = Noval) (cl : sdk_client) (opname : string) : ctx =
  let u = cl.cl_utility in
  u.u_make_context
    { (default_ctxspec ()) with cs_opname = Some opname;
      cs_ctrl = (match ctrl with Noval -> None | c -> Some c) }
    cl.cl_rootctx

let full_spec () : spec =
  new_spec (jo [("base", Str "http://h"); ("prefix", Str ""); ("suffix", Str "");
                ("path", Str "a"); ("method", Str "GET"); ("params", empty_map ());
                ("query", empty_map ()); ("headers", empty_map ()); ("step", Str "s")])

let resp ?(headers = []) status data : response =
  let lower = empty_map () in
  List.iter (fun (k, v) -> setp lower (String.lowercase_ascii k) v) headers;
  new_response (jo [("status", vint_of status);
                    ("statusText", Str (if status < 400 then "OK" else "ERR"));
                    ("headers", lower); ("json", json_thunk data); ("body", Str "body")])

let make_factory (cl : sdk_client) (made : value list ref) : entity_obj =
  let rootctx = match cl.cl_rootctx with Some c -> c | None -> assert false in
  let rec child () = {
    e_name = "x"; e_client = cl; e_utility = cl.cl_utility;
    e_entopts = empty_map (); e_data = empty_map (); e_match = empty_map ();
    e_entctx = rootctx; e_make = (fun () -> child ());
    e_data_set = (fun d -> made := !made @ [d]); e_data_get = (fun () -> empty_map ());
    e_match_set = (fun _ -> ()); e_match_get = (fun () -> empty_map ());
    (* Ops resolve to the ENTITY (see Sdk_types); this fake never runs them. *)
    e_load = (fun _ _ -> failwith "unused"); e_list = (fun _ _ -> []);
    e_create = (fun _ _ -> failwith "unused");
    e_update = (fun _ _ -> failwith "unused"); e_remove = (fun _ _ -> failwith "unused");
    e_deleted = false; e_mark_deleted = (fun () -> ());
    e_stream = (fun _ _ _ -> Seq.empty);
  } in
  child ()

(* make_options resolves the feature add-order into __derived__.featureorder:
   a map defaults test-first (so the test mock is the base transport), an
   explicit array preserves the developer order, and a map without test is
   deterministic (names sorted). *)
let resolve_order (feature : value) : value =
  let cl = client () in
  let ctx = mk_ctx cl "load" in
  ctx.c_options <- jo [("feature", feature)];
  ctx.c_config <- jo [("options", empty_map ())];
  cl.cl_utility.u_make_options ctx

let order_str (opts : value) : string =
  match getpath_s opts "__derived__.featureorder" with
  | List r -> String.concat "," (List.map (function Str s -> s | _ -> "") !r)
  | _ -> ""

let () =
  test "feature_order.map_test_first" (fun () ->
      let o = resolve_order (jo [("metrics", jo [("active", Bool true)]);
                                 ("test", jo [("active", Bool true)])]) in
      check_str "order" (order_str o) "test,metrics");

  test "feature_order.array_preserves_order" (fun () ->
      let o = resolve_order (ja [jo [("name", Str "metrics"); ("active", Bool true)];
                                 jo [("name", Str "test"); ("active", Bool true)]]) in
      check_str "order" (order_str o) "metrics,test";
      check_vbool "metrics active" (getpath_s o "feature.metrics.active") true;
      check_vbool "test active" (getpath_s o "feature.test.active") true);

  test "feature_order.map_no_test_deterministic" (fun () ->
      let o = resolve_order (jo [("retry", jo [("active", Bool true)]);
                                 ("cache", jo [("active", Bool true)])]) in
      check_str "order" (order_str o) "cache,retry");

  test "make_point.rejects_disallowed_op" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "nope" in
      ctx.c_options <- jo [("allow", jo [("op", Str "load")])];
      match cl.cl_utility.u_make_point ctx with
      | (_, Some e) -> check_str "code" e.err_code "point_op_allow"
      | _ -> failwith "expected error");

  test "make_point.rejects_no_endpoints" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "load" in
      match cl.cl_utility.u_make_point ctx with
      | (_, Some e) -> check_str "code" e.err_code "point_no_points"
      | _ -> failwith "expected error");

  test "make_point.single_point" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "load" in
      let point = jo [("method", Str "GET"); ("parts", ja [Str "a"])] in
      ctx.c_op.op_points <- ja [point];
      match cl.cl_utility.u_make_point ctx with
      | (out, None) -> check "returns point" (out == point); check "ctx.point" (ctx.c_point == point)
      | _ -> failwith "unexpected error");

  test "make_point.short_circuits_preset" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "load" in
      let preset = jo [("method", Str "GET")] in
      Hashtbl.replace ctx.c_out "point" (OPoint preset);
      match cl.cl_utility.u_make_point ctx with
      | (out, None) -> check "preset" (out == preset)
      | _ -> failwith "unexpected error");

  test "make_point.surfaces_feature_error" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "load" in
      let denied = ctx_make_error ctx "rbac_denied" "no permission" in
      Hashtbl.replace ctx.c_out "point" (OErr denied);
      match cl.cl_utility.u_make_point ctx with
      | (Noval, Some e) -> check "same err" (e == denied)
      | _ -> failwith "expected surfaced error");

  test "make_spec.short_circuits_preset" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "load" in
      let preset = new_spec (jo [("method", Str "GET")]) in
      Hashtbl.replace ctx.c_out "spec" (OSpec preset);
      match cl.cl_utility.u_make_spec ctx with
      | (Some s, None) -> check "preset" (s == preset)
      | _ -> failwith "unexpected");

  test "make_spec.surfaces_feature_error" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "load" in
      let boom = ctx_make_error ctx "boom" "boom" in
      Hashtbl.replace ctx.c_out "spec" (OErr boom);
      match cl.cl_utility.u_make_spec ctx with
      | (None, Some e) -> check "same" (e == boom)
      | _ -> failwith "expected error");

  test "make_response.guards" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "load" in
      ctx.c_spec <- None; ctx.c_response <- Some (resp 200 Noval); ctx.c_result <- Some (new_result (empty_map ()));
      (match cl.cl_utility.u_make_response ctx with (_, Some e) -> check_str "no_spec" e.err_code "response_no_spec" | _ -> failwith "e1");
      let ctx = mk_ctx cl "load" in
      ctx.c_spec <- Some (full_spec ()); ctx.c_response <- None; ctx.c_result <- Some (new_result (empty_map ()));
      (match cl.cl_utility.u_make_response ctx with (_, Some e) -> check_str "no_resp" e.err_code "response_no_response" | _ -> failwith "e2");
      let ctx = mk_ctx cl "load" in
      ctx.c_spec <- Some (full_spec ()); ctx.c_response <- Some (resp 200 Noval); ctx.c_result <- None;
      (match cl.cl_utility.u_make_response ctx with (_, Some e) -> check_str "no_res" e.err_code "response_no_result" | _ -> failwith "e3"));

  test "make_response.4xx_sets_err_and_headers" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "load" in
      ctx.c_spec <- Some (full_spec ()); ctx.c_response <- Some (resp ~headers:[("x-a", Str "1")] 404 Noval); ctx.c_result <- Some (new_result (empty_map ()));
      (match cl.cl_utility.u_make_response ctx with (_, None) -> () | _ -> failwith "unexpected err");
      let r = match ctx.c_result with Some r -> r | None -> assert false in
      check "err set" (r.rt_err <> None);
      check_int "status" r.rt_status 404;
      check_vstr "hdr" (getp r.rt_headers "x-a") "1";
      check "not ok" (not r.rt_ok));

  test "make_response.2xx_parses_body" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "load" in
      ctx.c_spec <- Some (full_spec ()); ctx.c_response <- Some (resp 200 (jo [("v", Num 1.)])); ctx.c_result <- Some (new_result (empty_map ()));
      ignore (cl.cl_utility.u_make_response ctx);
      let r = match ctx.c_result with Some r -> r | None -> assert false in
      check "ok" r.rt_ok; check_vnum "body.v" (getp r.rt_body "v") 1.);

  test "make_response.records_explain" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "load" ~ctrl:(jo [("explain", empty_map ())]) in
      ctx.c_spec <- Some (full_spec ()); ctx.c_response <- Some (resp 200 (jo [("v", Num 2.)])); ctx.c_result <- Some (new_result (empty_map ()));
      ignore (cl.cl_utility.u_make_response ctx);
      check "explain.result" (not (is_nullish (getp ctx.c_ctrl.ctrl_explain "result"))));

  test "make_result.guards" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "load" in
      ctx.c_spec <- None; ctx.c_result <- Some (new_result (empty_map ()));
      (match cl.cl_utility.u_make_result ctx with (_, Some e) -> check_str "no_spec" e.err_code "result_no_spec" | _ -> failwith "e1");
      let ctx = mk_ctx cl "load" in
      ctx.c_spec <- Some (full_spec ()); ctx.c_result <- None;
      (match cl.cl_utility.u_make_result ctx with (_, Some e) -> check_str "no_res" e.err_code "result_no_result" | _ -> failwith "e2"));

  test "make_result.list_wraps_resdata" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "list" in
      let made = ref [] in
      ctx.c_entity <- Some (make_factory cl made);
      ctx.c_spec <- Some (full_spec ());
      ctx.c_result <- Some (new_result (jo [("resdata", ja [jo [("a", Num 1.)]; jo [("a", Num 2.)]])]));
      (match cl.cl_utility.u_make_result ctx with (Some r, None) -> check_int "len" (size r.rt_resdata) 2 | _ -> failwith "unexpected");
      check_int "made" (List.length !made) 2);

  test "make_request.guards_spec" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "load" in
      ctx.c_spec <- None;
      match cl.cl_utility.u_make_request ctx with (_, Some e) -> check_str "no_spec" e.err_code "request_no_spec" | _ -> failwith "expected err");

  test "make_request.transport_error_on_response" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "load" in
      let boom = ctx_make_error ctx "boom" "boom" in
      let u = copy_utility cl.cl_utility in
      u.u_fetcher <- (fun _ _ _ -> (Noval, Some boom));
      ctx.c_utility <- Some u;
      ctx.c_spec <- Some (full_spec ());
      match u.u_make_request ctx with
      | (Some r, None) -> check "resp.err" (r.rs_err == Some boom || (match r.rs_err with Some e -> e == boom | None -> false))
      | _ -> failwith "unexpected");

  test "make_request.null_transport" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "load" in
      let u = copy_utility cl.cl_utility in
      u.u_fetcher <- (fun _ _ _ -> (Noval, None));
      ctx.c_utility <- Some u;
      ctx.c_spec <- Some (full_spec ());
      match u.u_make_request ctx with
      | (Some r, None) -> (match r.rs_err with Some e -> check_str "code" e.err_code "request_no_response" | None -> failwith "expected resp err")
      | _ -> failwith "unexpected");

  test "make_fetch_def.guards_spec" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "load" in
      ctx.c_spec <- None;
      match cl.cl_utility.u_make_fetch_def ctx with (_, Some e) -> check_str "code" e.err_code "fetchdef_no_spec" | _ -> failwith "expected err");

  test "make_fetch_def.serialises_body" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "load" in
      ctx.c_result <- None;
      let sp = full_spec () in sp.sp_method <- "POST"; sp.sp_body <- jo [("x", Num 1.)];
      ctx.c_spec <- Some sp;
      match cl.cl_utility.u_make_fetch_def ctx with
      | (fd, None) ->
        (match getp fd "body" with Str s -> check "has x" (String.length s > 0) | _ -> failwith "body not string");
        check "result inited" (ctx.c_result <> None)
      | _ -> failwith "unexpected");

  test "done.returns_resdata_on_success" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "load" in
      ctx.c_result <- Some (new_result (jo [("ok", Bool true); ("resdata", Num 42.)]));
      check_vnum "resdata" (cl.cl_utility.u_done ctx) 42.);

  test "done.raises_when_not_ok" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "load" in
      ctx.c_result <- Some (new_result (jo [("ok", Bool false)]));
      (try ignore (cl.cl_utility.u_done ctx); failwith "expected raise"
       with Sdk_error_exc _ -> ()));

  test "make_error.returns_resdata_when_throw_disabled" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "load" ~ctrl:(jo [("throw_err", Bool false)]) in
      ctx.c_result <- Some (new_result (jo [("ok", Bool false); ("resdata", Str "fallback")]));
      check_vstr "fallback" (cl.cl_utility.u_make_error ctx None) "fallback");

  test "make_error.records_explain" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "load" ~ctrl:(jo [("throw_err", Bool false); ("explain", empty_map ())]) in
      ctx.c_result <- Some (new_result (jo [("ok", Bool false)]));
      ignore (cl.cl_utility.u_make_error ctx None);
      check "explain.err" (not (is_nullish (getp ctx.c_ctrl.ctrl_explain "err"))));

  test "feature_add.appends_in_order" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "load" in
      let start = List.map (fun f -> f.f_name) cl.cl_features in
      let named n = let f = Sdk_features.base_feature () in f.f_name <- n; f in
      cl.cl_utility.u_feature_add ctx (named "aaa");
      cl.cl_utility.u_feature_add ctx (named "zzz");
      check "order" (List.map (fun f -> f.f_name) cl.cl_features = start @ ["aaa"; "zzz"]));

  test "feature_add.ordering" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "load" in
      cl.cl_features <- [];
      let named ?(opts = Noval) n = let f = Sdk_features.base_feature () in f.f_name <- n; f.f_options <- opts; f in
      let names () = List.map (fun f -> f.f_name) cl.cl_features in
      cl.cl_utility.u_feature_add ctx (named "a");
      cl.cl_utility.u_feature_add ctx (named "b");
      check "ab" (names () = ["a"; "b"]);
      cl.cl_utility.u_feature_add ctx (named ~opts:(jo [("__before__", Str "b")]) "z1");
      check "before" (names () = ["a"; "z1"; "b"]);
      cl.cl_utility.u_feature_add ctx (named ~opts:(jo [("__after__", Str "a")]) "z2");
      check "after" (names () = ["a"; "z2"; "z1"; "b"]);
      cl.cl_utility.u_feature_add ctx (named ~opts:(jo [("__replace__", Str "z1")]) "z3");
      check "replace" (names () = ["a"; "z2"; "z3"; "b"]);
      cl.cl_utility.u_feature_add ctx (named ~opts:(jo [("__before__", Str "missing")]) "z4");
      check "append_on_miss" (names () = ["a"; "z2"; "z3"; "b"; "z4"]));

  test "feature.transport_wrapping_order" (fun () ->
      let cl = client () in
      let ctx = match cl.cl_rootctx with Some c -> c | None -> assert false in
      let u = cl.cl_utility in
      let order = ref [] in
      u.u_fetcher <- (fun _ _ _ -> order := !order @ ["server"]; (jo [("status", Num 200.); ("statusText", Str "OK")], None));
      let wrap tag = let inner = u.u_fetcher in u.u_fetcher <- (fun c url fd -> order := !order @ [tag]; inner c url fd) in
      wrap "first"; wrap "second";
      ignore (u.u_fetcher ctx "http://h/a" (jo [("method", Str "GET"); ("headers", empty_map ())]));
      check "order" (!order = ["second"; "first"; "server"]));

  test "prepare_auth.apikey_prefix_space_joined" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "load" in
      cl.cl_options <- jo [("apikey", Str "K"); ("auth", jo [("prefix", Str "Bearer")])];
      ctx.c_spec <- Some (new_spec (jo [("headers", empty_map ())]));
      ignore (cl.cl_utility.u_prepare_auth ctx);
      check_vstr "auth" (getp (match ctx.c_spec with Some s -> s.sp_headers | None -> Noval) "authorization") "Bearer K");

  test "prepare_auth.raw_apikey" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "load" in
      cl.cl_options <- jo [("apikey", Str "K"); ("auth", jo [("prefix", Str "")])];
      ctx.c_spec <- Some (new_spec (jo [("headers", empty_map ())]));
      ignore (cl.cl_utility.u_prepare_auth ctx);
      check_vstr "auth" (getp (match ctx.c_spec with Some s -> s.sp_headers | None -> Noval) "authorization") "K");

  test "prepare_auth.empty_apikey_drops_header" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "load" in
      cl.cl_options <- jo [("apikey", Str ""); ("auth", jo [("prefix", Str "Bearer")])];
      ctx.c_spec <- Some (new_spec (jo [("headers", jo [("authorization", Str "stale")])]));
      ignore (cl.cl_utility.u_prepare_auth ctx);
      check "dropped" (is_noval (getp (match ctx.c_spec with Some s -> s.sp_headers | None -> Noval) "authorization")));

  test "prepare_auth.no_auth_block_drops_header" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "load" in
      cl.cl_options <- jo [("apikey", Str "K")];
      ctx.c_spec <- Some (new_spec (jo [("headers", jo [("authorization", Str "stale")])]));
      ignore (cl.cl_utility.u_prepare_auth ctx);
      check "dropped" (is_noval (getp (match ctx.c_spec with Some s -> s.sp_headers | None -> Noval) "authorization")));

  test "result_headers.no_headers_empty_map" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "load" in
      ctx.c_response <- Some (new_response (jo [("status", Num 200.)]));
      ctx.c_result <- Some (new_result (empty_map ()));
      cl.cl_utility.u_result_headers ctx;
      check "empty" (size (match ctx.c_result with Some r -> r.rt_headers | None -> Noval) = 0));

  test "result_body.skips_absent_body" (fun () ->
      let cl = client () in
      let ctx = mk_ctx cl "load" in
      ctx.c_response <- Some (new_response (jo [("status", Num 200.); ("json", json_thunk (jo [("a", Num 1.)]))]));
      ctx.c_result <- Some (new_result (empty_map ()));
      cl.cl_utility.u_result_body ctx;
      check "body none" (is_noval (match ctx.c_result with Some r -> r.rt_body | None -> Noval)))
