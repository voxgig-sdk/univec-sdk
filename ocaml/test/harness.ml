(* Offline feature-test harness (mirrors the py feature_harness).
 *
 * Drives each real generated feature class through a faithful miniature of
 * the operation pipeline against a configurable mock transport — the same
 * hook order and short-circuit rules as the generated op runner, but with no
 * live server and no API-specific fixtures. Feature instances come from the
 * generated Sdk_config.make_feature, so only features present in this SDK are
 * exercised (see has_feature). *)

open Voxgig_struct
open Sdk_types
open Sdk_helpers
open Sdk_runtime

(* ----- deterministic virtual clock ----- *)
type clock = { mutable t : float }
let make_clock ?(start = 0.) () : clock = { t = start }
let clock_now (c : clock) : float = c.t
let clock_sleep (c : clock) (ms : float) : unit = c.t <- c.t +. (if ms < 0. then 0. else ms)
let clock_advance (c : clock) (ms : float) : unit = c.t <- c.t +. ms
let clock_now_fn (c : clock) : value = vfunc0 (fun () -> Num c.t)
let clock_sleep_fn (c : clock) : value = vfunc1 (fun v -> (match v with Num ms -> clock_sleep c ms | _ -> ()); Noval)

(* ----- transport-shaped response ----- *)
let make_response ?(headers = []) (status : int) (data : value) : value =
  let lower = empty_map () in
  List.iter (fun (k, v) -> setp lower (String.lowercase_ascii k) v) headers;
  jo [("status", vint_of status);
      ("statusText", Str (if status < 400 then "OK" else "ERR"));
      ("body", Str "not-used"); ("json", json_thunk data); ("headers", lower)]

type server = ctx -> string -> value -> (value * sdk_error option)

let default_server () : server =
  fun _ctx _url fetchdef ->
    let meth = match getp fetchdef "method" with Str s -> String.uppercase_ascii s | _ -> "GET" in
    if meth = "GET" then (make_response 200 (jo [("ok", Bool true); ("method", Str meth)]), None)
    else (make_response 200 (jo [("ok", Bool true); ("method", Str meth); ("echo", getp fetchdef "body")]), None)

(* reply : call-number -> fetchdef -> (response, err) *)
let recording_server ?(reply : (int -> value -> (value * sdk_error option)) option) () : server * value list ref =
  let calls = ref [] in
  let srv ctx url fetchdef =
    ignore ctx;
    calls := !calls @ [jo [("url", Str url); ("fetchdef", fetchdef)]];
    match reply with
    | Some r -> r (List.length !calls) fetchdef
    | None -> (make_response 200 (jo [("ok", Bool true); ("n", vint_of (List.length !calls))]), None)
  in
  (srv, calls)

(* ----- SDK feature presence ----- *)
let has_feature (name : string) : bool =
  match getp (Sdk_config.make_config ()) "feature" with
  | Map _ as fm -> not (is_nullish (getp fm name))
  | _ -> false

(* ----- op result ----- *)
type op_result = {
  or_ok : bool;
  or_data : value;
  or_result : result option;
  or_ctx : ctx;
  or_error : sdk_error option;
  or_response : value;
}

type harness = {
  h_base : string;
  h_headers : value;
  h_client : sdk_client;
  h_utility : utility;
  h_rootctx : ctx;
}

let make_client ?(server : server option) ?(mode = "test") ?(base = "http://api.test")
    ?(headers : (string * value) list = []) (features : (string * value) list) : harness =
  let hheaders = empty_map () in
  List.iter (fun (k, v) -> setp hheaders k v) headers;
  let srv = match server with Some s -> s | None -> default_server () in
  let utility = new_utility () in
  register utility;
  utility.u_fetcher <- srv;
  utility.u_param <- (fun ctx name ->
      let key = match name with Str s -> s | _ -> "" in
      match ctx.c_spec with
      | Some sp -> let v = getp sp.sp_params key in if not (is_noval v) then v else getp sp.sp_query key
      | None -> Noval);
  let client = { cl_mode = mode; cl_features = [];
                 cl_options = jo [("base", Str base); ("headers", clone hheaders); ("feature", empty_map ())];
                 cl_utility = utility; cl_rootctx = None; cl_track = empty_map () } in
  let rootctx = make_context_impl { (default_ctxspec ()) with cs_client = Some client; cs_utility = Some utility } None in
  rootctx.c_op <- new_operation (jo [("name", Str "root"); ("entity", Str "_")]);
  client.cl_rootctx <- Some rootctx;
  List.iter (fun (name, opts) ->
      if has_feature name then begin
        let ftr = Sdk_config.make_feature name in
        let fopts = jo [("active", Bool true)] in
        (match opts with Map _ -> List.iter (fun k -> setp fopts k (getp opts k)) (keysof opts) | _ -> ());
        setp (getp client.cl_options "feature") name fopts;
        ftr.f_init rootctx fopts;
        client.cl_features <- client.cl_features @ [ftr]
      end) features;
  feature_hook_util rootctx "PostConstruct";
  { h_base = base; h_headers = hheaders; h_client = client; h_utility = utility; h_rootctx = rootctx }

let feature (h : harness) (name : string) : feature option =
  List.find_opt (fun f -> f.f_name = name) h.h_client.cl_features

let default_method op = match op with "create" -> "POST" | "update" -> "PATCH" | "remove" -> "DELETE" | _ -> "GET"

let build_url (sp : spec) : string =
  let q = match sp.sp_query with Map _ as m -> m | _ -> empty_map () in
  let keys = List.filter (fun k -> not (is_noval (getp q k))) (List.sort compare (keysof q)) in
  let esc s = match escurl (Str s) with Str x -> x | _ -> s in
  let qs = String.concat "&" (List.map (fun k -> esc k ^ "=" ^ esc (match getp q k with Str s -> s | Noval | Null -> "" | v -> js_string v)) keys) in
  sp.sp_base ^ sp.sp_path ^ (if qs <> "" then "?" ^ qs else "")

let populate_result (ctx : ctx) (response : value) (fetch_err : sdk_error option) : unit =
  let result = new_result (empty_map ()) in
  ctx.c_result <- Some result;
  (match fetch_err with
   | Some e -> result.rt_err <- Some e
   | None ->
     if is_noval response || response = Null then
       result.rt_err <- Some (ctx_make_error ctx "request_no_response" "response: undefined")
     else match response with
       | Map _ ->
         result.rt_status <- to_int (getp response "status");
         result.rt_status_text <- (match getp response "statusText" with Str s -> s | _ -> "");
         result.rt_headers <- (match getp response "headers" with Map _ as m -> clone m | _ -> empty_map ());
         (match getp response "json" with Func _ as fn -> (try result.rt_body <- call_json fn with _ -> ()) | _ -> ());
         result.rt_resdata <- result.rt_body;
         (if result.rt_status >= 400 then
            result.rt_err <- Some (ctx_make_error ctx "request_status"
              ("request: " ^ string_of_int result.rt_status ^ ": " ^ result.rt_status_text)));
         if result.rt_err = None then result.rt_ok <- true
       | _ -> result.rt_err <- Some (ctx_make_error ctx "op_failed" "invalid response"))

let op (h : harness) ?(op = "load") ?(entity = "widget") ?(method_ : string option)
    ?(path : string option) ?(query : value option) ?(headers : (string * value) list option)
    ?(body = Noval) ?(ctrl = Noval) () : op_result =
  let opname = op in
  let meth = match method_ with Some m -> m | None -> default_method opname in
  let ctrl_map = match ctrl with Map _ as m -> m | _ -> empty_map () in
  let ctx = make_context_impl
      { (default_ctxspec ()) with cs_client = Some h.h_client; cs_utility = Some h.h_utility; cs_ctrl = Some ctrl_map }
      (Some h.h_rootctx) in
  ctx.c_op <- new_operation (jo [("name", Str opname); ("entity", Str entity)]);
  feature_hook_util ctx "PostConstructEntity";
  let finish_err (err : sdk_error) =
    ctx.c_ctrl.ctrl_err <- Some err;
    feature_hook_util ctx "PreUnexpected";
    { or_ok = false; or_error = Some err; or_result = ctx.c_result; or_ctx = ctx; or_data = Noval; or_response = Noval }
  in
  try
    feature_hook_util ctx "PrePoint";
    (match Hashtbl.find_opt ctx.c_out "point" with Some (OErr e) -> raise (Sdk_error_exc e) | _ -> ());
    feature_hook_util ctx "PreSpec";
    let spec =
      match Hashtbl.find_opt ctx.c_out "spec" with
      | Some (OSpec s) -> s
      | _ ->
        let merged = match clone h.h_headers with Map _ as m -> m | _ -> empty_map () in
        (match headers with Some hs -> List.iter (fun (k, v) -> setp merged k v) hs | None -> ());
        new_spec (jo [("method", Str meth); ("base", Str h.h_base);
                      ("path", Str (match path with Some p -> p | None -> "/" ^ entity));
                      ("params", empty_map ()); ("headers", merged);
                      ("query", (match query with Some q -> q | None -> empty_map ()));
                      ("body", body); ("step", Str "start")])
    in
    ctx.c_spec <- Some spec;
    feature_hook_util ctx "PreRequest";
    spec.sp_url <- build_url spec;
    let response = ref Noval and fetch_err = ref None in
    (match Hashtbl.find_opt ctx.c_out "request" with
     | Some (OResponse _) -> ()
     | _ ->
       let fetchdef = jo [("url", Str spec.sp_url); ("method", Str spec.sp_method);
                          ("headers", spec.sp_headers); ("body", spec.sp_body)] in
       let (f, e) = (cu ctx).u_fetcher ctx spec.sp_url fetchdef in
       response := f; fetch_err := e);
    let resp_val = !response in
    feature_hook_util ctx "PreResponse";
    populate_result ctx !response !fetch_err;
    feature_hook_util ctx "PreResult";
    feature_hook_util ctx "PreDone";
    (match ctx.c_result with
     | Some r when r.rt_ok ->
       { or_ok = true; or_data = r.rt_resdata; or_result = Some r; or_ctx = ctx; or_error = None; or_response = resp_val }
     | _ ->
       let err = match ctx.c_result with
         | Some r -> (match r.rt_err with Some e -> e | None -> ctx_make_error ctx "op_failed" "operation failed")
         | None -> ctx_make_error ctx "op_failed" "operation failed" in
       raise (Sdk_error_exc err))
  with
  | Sdk_error_exc err -> finish_err err
  | e -> finish_err (ctx_make_error ctx "op_failed" (Printexc.to_string e))
