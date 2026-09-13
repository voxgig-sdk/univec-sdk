(* Univec SDK primary-utility corpus.
 *
 * Drives the SHARED language-neutral corpus (.sdk/test/test.json -> "primary")
 * through this SDK's request-shaping utilities, so the cases cannot drift from
 * the reference implementation. Each section is looked up by name and executed
 * on the VENDORED @voxgig/omni engine through Omni_resolver, exactly as the
 * ts/js reference harness does.
 *
 * Every section here uses `runset_args`: a `ctx` entry arrives as `args.(0)`,
 * a MAP, which the call site turns into a LIVE typed context, runs the
 * utility on, and writes the observable state back into — which is what
 * makes `match: {ctx: ...}` (retargeted onto `match: {args: {"0": ...}}` by
 * the resolver, decision 3) read the POST-call state rather than a stale
 * pre-call copy.
 *)

open Voxgig_struct
open Sdk_types
open Sdk_helpers
open Sdk_runtime

module O = Omni
module R = Omni_resolver

let client () : sdk_client = Sdk_client.test ()

(* A client built from a section's DEF.setup.a block. prepare_auth reads the
 * CLIENT's options, as the ts reference does via client.options(), so a
 * section's setup cannot reach it through ctx.options. *)
let client_for (r : R.run) (name : string) : sdk_client =
  match R.tostruct (R.getset r [name; "DEF"; "setup"; "a"]) with
  | Map _ as setup -> Sdk_client.test_with Noval setup
  | _ -> Sdk_client.test ()

(* A LIVE context from a corpus map. The utilities read and MUTATE spec,
 * result and response through their record types, so a bare value map leaves
 * them nothing to work on and every match reads null. *)
let ctx_from (cl : sdk_client) (ctxmap : value) : ctx =
  let u = cl.cl_utility in
  (* The corpus names the op — {"ctx": {"opname": "create"}} — and
   * prepare_method reads it. Hardcoding "load" made every method GET. *)
  (* Only when the corpus names one. Defaulting to "load" made the SDK report
   * the wrong operation in error messages the corpus matches on — it expects
   * "unknown operation" where no op is named. *)
  let cs =
    match R.getp ctxmap "opname" with
    | Str s -> { (default_ctxspec ()) with cs_opname = Some s }
    | _ -> default_ctxspec ()
  in
  let c = u.u_make_context cs cl.cl_rootctx in
  (match R.getp ctxmap "spec" with
   | Map _ as m -> c.c_spec <- Some (new_spec m)
   | _ -> ());
  (match R.getp ctxmap "result" with
   | Map _ as m ->
     let rt = new_result m in
     (* new_result hardcodes rt_err = None, so a corpus result carrying an err
      * arrives empty and result_basic has no previous message to prepend —
      * it produced "request: 400: BAD" where the contract says
      * "Foo: request: 400: BAD". The lua and elixir drivers build it too. *)
     (match R.getp m "err" with
      | Map _ as em ->
        (match R.getp em "message" with
         | Str msg when msg <> "" ->
           rt.rt_err <- Some { err_code = ""; err_msg = msg; err_result = Noval; err_spec = Noval }
         | _ -> ())
      | _ -> ());
     c.c_result <- Some rt
   | _ -> ());
  (match R.getp ctxmap "response" with
   | Map _ as m ->
     let rs = new_response m in
     (* result_body_util reads response.json and requires it to be CALLABLE;
      * the corpus supplies a plain `body`, so wrap it, as the lua and elixir
      * drivers do. Without this every ctx.result.body match reads empty. *)
     (match R.getp m "body" with
      | Noval -> ()
      | b -> rs.rs_json <- Func (fun _ _ _ _ -> b));
     (* Header names arrive from the wire in any case and the contract is
      * lowercase; the lua and elixir drivers normalise here rather than in
      * result_headers_util, which copies them verbatim. *)
     (match R.getp m "headers" with
      | Map hm ->
        let low = empty_map () in
        List.iter (fun (k, v) -> ignore (setprop low (Str (String.lowercase_ascii k)) v))
          hm.entries;
        rs.rs_headers <- low
      | _ -> ());
     c.c_response <- Some rs
   | _ -> ());
  (match R.getp ctxmap "point" with
   | Map _ as m -> c.c_point <- m
   | _ -> ());
  (match R.getp ctxmap "reqdata" with Noval -> () | v -> c.c_reqdata <- v);
  (match R.getp ctxmap "reqmatch" with Noval -> () | v -> c.c_reqmatch <- v);
  (match R.getp ctxmap "data" with Noval -> () | v -> c.c_data <- v);
  (match R.getp ctxmap "match" with Noval -> () | v -> c.c_match <- v);
  c

(* The corpus speaks camelCase; this port stores rs_status_text / rt_ok. A
 * neutral-named view is what the match assertions read. *)
let result_value (r : result option) : value =
  match r with
  | None -> Noval
  | Some rt -> result_to_value rt

let arg (args : value array) (index : int) : value =
  if index < Array.length args then args.(index) else Noval

(* omni reports a subject failure by its exception MESSAGE, and understands
 * `Failure` (and its own `Omni_error`) directly; anything else renders
 * through Printexc, which turns a branded SDK error into
 * "Sdk_types.Sdk_error_exc(_)" and loses the message the corpus matches on.
 * Convert here rather than teaching the shared resolver about SDK types. *)
let run_guarded f c =
  try f c with Sdk_error_exc e -> raise (Failure e.err_msg)

(* Publish the MUTATED ctx back onto the corpus map the match reads.
 * The resolver retargets `match: {ctx: ...}` onto `match: {args: {"0": ...}}`
 * and writes the argument array back after the call, so this map IS what the
 * assertions read — but only for the state written here. Neutral names,
 * because the corpus is camelCase and this port stores rs_status_text/rt_ok. *)
let publish (ctxmap : value) (c : ctx) =
  (match c.c_spec with
   | Some sp -> ignore (setprop ctxmap (Str "spec") (spec_to_value sp))
   | None -> ());
  (match c.c_result with
   | Some _ -> ignore (setprop ctxmap (Str "result") (result_value c.c_result))
   | None -> ());
  (match c.c_response with
   | Some _ -> ignore (setprop ctxmap (Str "response") (Str R.existsmark))
   | None -> ());
  ()

let () =
  let testfile = if Array.length Sys.argv > 1 then Sys.argv.(1) else "../.sdk/test/test.json" in
  let r = R.make_run testfile "primary" in

  let cl = client () in
  let u = cl.cl_utility in

  (* Sections configured by their own DEF.setup block get their own client. *)
  let primary_ctx_with cl2 name f =
    R.runset_args r name (R.getset r [name; "basic"])
      (fun args ->
         let ctxmap = arg args 0 in
         let c = ctx_from cl2 ctxmap in
         let out = run_guarded f c in
         publish ctxmap c;
         out)
  in

  let primary_ctx name f = primary_ctx_with cl name f in

  primary_ctx "done" (fun c -> u.u_done c);
  primary_ctx "makeUrl" (fun c -> match make_url_util c with (s, _) -> Str s);
  primary_ctx "makeRequest"
    (fun c -> ignore (make_request_util c); result_value c.c_result);
  primary_ctx "makeResponse"
    (fun c -> ignore (make_response_util c); result_value c.c_result);
  primary_ctx_with (client_for r "makeSpec") "makeSpec"
    (fun c -> match make_spec_util c with
       | (Some s, _) -> spec_to_value s | _ -> Noval);
  primary_ctx_with (client_for r "prepareAuth") "prepareAuth"
    (fun c -> ignore (prepare_auth_util c);
      match c.c_spec with Some s -> spec_to_value s | None -> Noval);
  primary_ctx "prepareBody" (fun c -> prepare_body_util c);
  primary_ctx "prepareHeaders" (fun c -> prepare_headers_util c);
  primary_ctx "prepareMethod"
    (fun c -> match prepare_method_util c with "" -> Noval | m -> Str m);
  primary_ctx "prepareParams" (fun c -> prepare_params_util c);
  primary_ctx "preparePath" (fun c -> Str (prepare_path_util c));
  primary_ctx "prepareQuery" (fun c -> prepare_query_util c);
  primary_ctx "resultBasic" (fun c -> result_basic_util c; result_value c.c_result);
  primary_ctx "resultBody" (fun c -> result_body_util c; result_value c.c_result);
  primary_ctx "resultHeaders" (fun c -> result_headers_util c; result_value c.c_result);
  primary_ctx "transformRequest" (fun c -> transform_request_util c);
  primary_ctx "transformResponse" (fun c -> transform_response_util c);

  (* Sections that take a bare map or explicit args rather than a ctx. *)
  let primary_args name f =
    R.runset_args r name (R.getset r [name; "basic"]) (fun args -> run_guarded f args)
  in

  primary_args "makeContext" (fun args ->
      let inv = arg args 0 in
      let c = ctx_from cl inv in
      jo [("op", jo [("entity", Str c.c_op.op_entity); ("name", Str c.c_op.op_name);
                     ("input", Str c.c_op.op_input); ("points", c.c_op.op_points)])]);

  primary_args "makeOptions" (fun args ->
      let inv = arg args 0 in
      let c = ctx_from cl (jo []) in
      c.c_config <- R.getp inv "config";
      c.c_options <- R.getp inv "options";
      make_options_util c);

  primary_args "makeError" (fun args ->
      let a0 = arg args 0 in
      let a1 = arg args 1 in
      let c = ctx_from cl a0 in
      let msg = (match R.getp a1 "message" with Str m -> m | _ -> "") in
      let e = { err_code = ""; err_msg = msg; err_result = Noval; err_spec = Noval } in
      let out = make_error_util c (if msg = "" then None else Some e) in
      publish a0 c;
      out);

  primary_args "operator" (fun args ->
      let inv = arg args 0 in
      let op = new_operation inv in
      jo [("entity", Str op.op_entity); ("input", Str op.op_input);
          ("name", Str op.op_name); ("points", op.op_points)]);

  primary_args "param" (fun args ->
      let a0 = arg args 0 in
      let a1 = arg args 1 in
      let c = ctx_from cl a0 in
      let out = param_util c a1 in
      publish a0 c;
      out);

  R.report r "PRIMARY CORPUS: "
