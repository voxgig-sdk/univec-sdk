(* Univec SDK runtime: the operation pipeline.
 *
 * This one module implements everything the generated per-API code wires
 * together: the pipeline object constructors, the context builder, all the
 * `*_util` utilities (the py utility/ layer), the utility registrar, the 18
 * features + the transport it wraps, and the API-agnostic client helpers
 * (make_client_base / direct / prepare). Utilities and features reference
 * each other through the closure-valued `utility` record (the registrar
 * pattern), so there is no OCaml module cycle. *)

open Voxgig_struct
open Sdk_types
open Sdk_helpers

(* ------------------------------------------------------------------ *)
(* small local helpers                                                 *)
(* ------------------------------------------------------------------ *)

let substr_contains (hay : string) (needle : string) : bool =
  let hl = String.length hay and nl = String.length needle in
  if nl = 0 then true
  else
    let rec go i =
      if i + nl > hl then false
      else if String.sub hay i nl = needle then true
      else go (i + 1)
    in
    go 0

let str_replace_all (s : string) (find : string) (repl : string) : string =
  if find = "" then s
  else begin
    let flen = String.length find and n = String.length s in
    let buf = Buffer.create n in
    let i = ref 0 in
    while !i < n do
      if !i + flen <= n && String.sub s !i flen = find then
        (Buffer.add_string buf repl; i := !i + flen)
      else (Buffer.add_char buf s.[!i]; incr i)
    done;
    Buffer.contents buf
  end

let escurl_s (s : string) : string = match escurl (Str s) with Str x -> x | _ -> s
let escre_s (s : string) : string = match escre (Str s) with Str x -> x | _ -> s

let random_hex4 () = Printf.sprintf "%04x" (Random.int 0x10000)
let random_id16 () =
  random_hex4 () ^ random_hex4 () ^ random_hex4 () ^ random_hex4 ()

(* val-as-string coercion (JS String(v)) *)
let vstring (v : value) : string =
  match v with Str s -> s | Noval | Null -> "" | _ -> js_string v

(* header lookup (case-insensitive) over a struct map *)
let header_ci (headers : value) (name : string) : value =
  let lname = String.lowercase_ascii name in
  let ks = keysof headers in
  let rec go = function
    | [] -> Noval
    | k :: rest -> if String.lowercase_ascii k = lname then getp headers k else go rest
  in
  go ks

(* ------------------------------------------------------------------ *)
(* pipeline object constructors                                        *)
(* ------------------------------------------------------------------ *)

let new_control () : control =
  { ctrl_throw = None; ctrl_err = None; ctrl_explain = Noval;
    ctrl_actor = Noval; ctrl_paging = Noval }

let new_operation (opmap : value) : operation =
  let gstr k d = match getp opmap k with Str s when s <> "" -> s | _ -> d in
  let points =
    match getp opmap "points" with
    | List r -> lst (List.filter (fun t -> match t with Map _ -> true | _ -> false) !r)
    | _ -> empty_list ()
  in
  { op_entity = gstr "entity" "_"; op_name = gstr "name" "_";
    op_input = gstr "input" "_"; op_points = points;
    op_alias = to_map (getp opmap "alias") }

let new_spec (m : value) : spec =
  let gs k d = match getp m k with Str s -> s | _ -> d in
  let gv k d = match getp m k with Noval -> d | v -> v in
  { sp_parts = gv "parts" (empty_list ());
    sp_headers = gv "headers" (empty_map ());
    sp_alias = gv "alias" (empty_map ());
    sp_base = gs "base" ""; sp_prefix = gs "prefix" ""; sp_suffix = gs "suffix" "";
    sp_params = gv "params" (empty_map ());
    sp_query = gv "query" (empty_map ());
    sp_step = gs "step" ""; sp_method = gs "method" "GET";
    sp_body = getp m "body";
    sp_url = gs "url" ""; sp_path = gs "path" "" }

let new_response (m : value) : response =
  { rs_status = (match getp m "status" with Num n -> int_of_float n | _ -> -1);
    rs_status_text = (match getp m "statusText" with Str s -> s | _ -> "");
    rs_headers = getp m "headers";
    rs_json = (match getp m "json" with Func _ as f -> f | _ -> Noval);
    rs_body = getp m "body";
    rs_err = None }

let new_result (m : value) : result =
  { rt_ok = (getp m "ok" = Bool true);
    rt_status = (match getp m "status" with Num n -> int_of_float n | _ -> -1);
    rt_status_text = (match getp m "statusText" with Str s -> s | _ -> "");
    rt_headers = (match getp m "headers" with Map _ as h -> h | _ -> empty_map ());
    rt_body = getp m "body";
    rt_err = None;
    rt_resdata = getp m "resdata";
    rt_resmatch = (match getp m "resmatch" with Map _ as h -> h | _ -> Noval);
    rt_paging = Noval; rt_streaming = false; rt_stream = None }

let spec_to_value (sp : spec) : value =
  let out = jo [
    ("base", Str sp.sp_base); ("prefix", Str sp.sp_prefix); ("suffix", Str sp.sp_suffix);
    ("path", Str sp.sp_path); ("method", Str sp.sp_method);
    ("params", sp.sp_params); ("query", sp.sp_query); ("headers", sp.sp_headers);
    ("step", Str sp.sp_step); ("alias", sp.sp_alias) ] in
  if not (is_noval sp.sp_body) then setp out "body" sp.sp_body;
  if sp.sp_url <> "" then setp out "url" (Str sp.sp_url);
  out

let result_to_value (rt : result) : value =
  let out = jo [
    ("ok", Bool rt.rt_ok); ("status", vint_of rt.rt_status);
    ("statusText", Str rt.rt_status_text); ("headers", rt.rt_headers) ] in
  if not (is_noval rt.rt_body) then setp out "body" rt.rt_body;
  (match rt.rt_err with Some e -> setp out "err" (jo [("message", Str e.err_msg)]) | None -> ());
  if not (is_noval rt.rt_resdata) then setp out "resdata" rt.rt_resdata;
  if not (is_noval rt.rt_resmatch) then setp out "resmatch" rt.rt_resmatch;
  if not (is_noval rt.rt_paging) then setp out "paging" rt.rt_paging;
  out

let err_to_value (e : sdk_error) : value =
  jo [("code", Str e.err_code); ("message", Str e.err_msg)]

(* ------------------------------------------------------------------ *)
(* ctxspec + context                                                   *)
(* ------------------------------------------------------------------ *)

let default_ctxspec () : ctxspec =
  { cs_opname = None; cs_client = None; cs_utility = None; cs_ctrl = None;
    cs_meta = None; cs_config = None; cs_entopts = None; cs_options = None;
    cs_entity = None; cs_shared = None; cs_opmap = None; cs_data = None;
    cs_reqdata = None; cs_match = None; cs_reqmatch = None; cs_point = None;
    cs_spec = None; cs_result = None; cs_response = None }

let resolve_op (ctx : ctx) (opname : string) : operation =
  let entname = match ctx.c_entity with Some e -> e.e_name | None -> "_" in
  let cache_key = entname ^ ":" ^ opname in
  match Hashtbl.find_opt ctx.c_opmap cache_key with
  | Some op -> op
  | None ->
    if opname = "" then new_operation (empty_map ())
    else begin
      let opcfg = getpath_s ctx.c_config ("entity." ^ entname ^ ".op." ^ opname) in
      let inpt = if opname = "update" || opname = "create" then "data" else "match" in
      let points =
        match to_map opcfg with
        | Map _ -> (match getp opcfg "points" with List _ as l -> l | _ -> empty_list ())
        | _ -> empty_list ()
      in
      let op = new_operation
          (jo [("entity", Str entname); ("name", Str opname);
               ("input", Str inpt); ("points", points)]) in
      Hashtbl.replace ctx.c_opmap cache_key op;
      op
    end

let make_context_impl (cs : ctxspec) (basectx : ctx option) : ctx =
  let id = "C" ^ string_of_int (10000000 + Random.int 90000000) in
  let client =
    match cs.cs_client with Some _ as c -> c
    | None -> (match basectx with Some b -> b.c_client | None -> None) in
  let utility =
    match cs.cs_utility with Some _ as u -> u
    | None -> (match basectx with Some b -> b.c_utility | None -> None) in
  let ctrl =
    match cs.cs_ctrl with
    | Some (Map _ as cr) ->
      let c = new_control () in
      (match getp cr "throw_err" with
       | Bool b -> c.ctrl_throw <- Some b
       | _ -> (match getp cr "throw" with Bool b -> c.ctrl_throw <- Some b | _ -> ()));
      (match getp cr "explain" with Map _ as m -> c.ctrl_explain <- m | _ -> ());
      (match getp cr "actor" with Noval -> () | a -> c.ctrl_actor <- a);
      (match getp cr "paging" with Map _ as m -> c.ctrl_paging <- m | _ -> ());
      c
    | _ -> (match basectx with Some b -> b.c_ctrl | None -> new_control ())
  in
  let meta =
    match cs.cs_meta with Some (Map _ as m) -> m
    | _ -> (match basectx with
        | Some b -> (match b.c_meta with Map _ as m -> m | _ -> empty_map ())
        | None -> empty_map ()) in
  let config =
    match cs.cs_config with Some (Map _ as m) -> m
    | _ -> (match basectx with Some b -> b.c_config | None -> Noval) in
  let entopts =
    match cs.cs_entopts with Some (Map _ as m) -> m
    | _ -> (match basectx with Some b -> b.c_entopts | None -> Noval) in
  let options =
    match cs.cs_options with Some (Map _ as m) -> m
    | _ -> (match basectx with Some b -> b.c_options | None -> Noval) in
  let entity =
    match cs.cs_entity with Some _ as e -> e
    | None -> (match basectx with Some b -> b.c_entity | None -> None) in
  let shared =
    match cs.cs_shared with Some (Map _ as m) -> m
    | _ -> (match basectx with Some b -> b.c_shared | None -> Noval) in
  let opmap =
    match cs.cs_opmap with Some h -> h
    | None -> (match basectx with Some b -> b.c_opmap | None -> Hashtbl.create 16) in
  let mapof = function Some d -> (match to_map d with Map _ as m -> m | _ -> empty_map ()) | None -> empty_map () in
  let data = mapof cs.cs_data and reqdata = mapof cs.cs_reqdata
  and mtch = mapof cs.cs_match and reqmatch = mapof cs.cs_reqmatch in
  let point =
    match cs.cs_point with Some (Map _ as m) -> m
    | _ -> (match basectx with Some b -> b.c_point | None -> Noval) in
  let spec = match cs.cs_spec with Some _ as s -> s | None -> (match basectx with Some b -> b.c_spec | None -> None) in
  let result = match cs.cs_result with Some _ as r -> r | None -> (match basectx with Some b -> b.c_result | None -> None) in
  let response = match cs.cs_response with Some _ as r -> r | None -> (match basectx with Some b -> b.c_response | None -> None) in
  let ctx = {
    c_id = id; c_out = Hashtbl.create 8; c_ctrl = ctrl; c_meta = meta;
    c_client = client; c_utility = utility; c_op = new_operation (empty_map ());
    c_point = point; c_config = config; c_entopts = entopts; c_options = options;
    c_opmap = opmap; c_response = response; c_result = result; c_spec = spec;
    c_data = data; c_reqdata = reqdata; c_match = mtch; c_reqmatch = reqmatch;
    c_entity = entity; c_shared = shared; c_scratch = Hashtbl.create 8;
  } in
  let opname = match cs.cs_opname with Some s -> s | None -> "" in
  ctx.c_op <- resolve_op ctx opname;
  ctx

(* ------------------------------------------------------------------ *)
(* utilities                                                           *)
(* ------------------------------------------------------------------ *)

let client_options_map (client : sdk_client) : value =
  match clone client.cl_options with Map _ as m -> m | _ -> empty_map ()

let clean_util (_ctx : ctx) (v : value) : value = v

let make_error_util (ctx : ctx) (err_opt : sdk_error option) : value =
  let op = ctx.c_op in
  let opname = if op.op_name = "" || op.op_name = "_" then "unknown operation" else op.op_name in
  let result = match ctx.c_result with Some r -> r | None -> new_result (empty_map ()) in
  result.rt_ok <- false;
  let err =
    match err_opt with
    | Some e -> e
    | None -> (match result.rt_err with Some e -> e | None -> ctx_make_error ctx "unknown" "unknown error")
  in
  let msg = "UnivecSDK: " ^ opname ^ ": " ^ err.err_msg in
  let msg = match (cu ctx).u_clean ctx (Str msg) with Str s -> s | _ -> msg in
  result.rt_err <- None;
  (match ctx.c_ctrl.ctrl_explain with
   | Map _ -> setp ctx.c_ctrl.ctrl_explain "err" (jo [("message", Str msg)])
   | _ -> ());
  let sdk_err = {
    err_code = err.err_code; err_msg = msg;
    err_result = (cu ctx).u_clean ctx (result_to_value result);
    err_spec = (match ctx.c_spec with Some s -> (cu ctx).u_clean ctx (spec_to_value s) | None -> Noval);
  } in
  ctx.c_ctrl.ctrl_err <- Some sdk_err;
  (* Fire PreUnexpected so observability features (metrics, telemetry, audit,
     debug) close/record error paths that never reach PreDone (e.g. a PrePoint
     rbac short-circuit). Fires after ctrl_err is set so hooks can read the
     error; features guard against double-recording when PreDone already fired. *)
  (cu ctx).u_feature_hook ctx "PreUnexpected";
  if ctx.c_ctrl.ctrl_throw = Some false then result.rt_resdata
  else raise (Sdk_error_exc sdk_err)

let done_util (ctx : ctx) : value =
  (match ctx.c_ctrl.ctrl_explain with
   | Map _ as ex ->
     ctx.c_ctrl.ctrl_explain <- (cu ctx).u_clean ctx ex;
     (match ctx.c_ctrl.ctrl_explain with
      | Map _ as ex2 -> (match getp ex2 "result" with Map _ as r -> ignore (delprop r (Str "err")) | _ -> ())
      | _ -> ())
   | _ -> ());
  match ctx.c_result with
  | Some result when result.rt_ok -> result.rt_resdata
  | _ -> (cu ctx).u_make_error ctx None

(* ----- feature utilities ----- *)

let feature_hook_util (ctx : ctx) (name : string) : unit =
  match ctx.c_client with
  | None -> ()
  | Some client -> List.iter (fun f -> f.f_hook name ctx) client.cl_features

(* Convenience used by the generated op-runner: each pipeline-stage hook
 * marker line is rewritten by the generator into a `feature_hook ctx "PreX"`
 * call that fans the hook out to every active feature. *)
let feature_hook (ctx : ctx) (name : string) : unit =
  (cu ctx).u_feature_hook ctx name

let feature_add_util (ctx : ctx) (f : feature) : unit =
  let client = cc ctx in
  let pos key =
    match to_map f.f_options with
    | Map _ -> (match getp f.f_options key with Str s -> Some s | _ -> None)
    | _ -> None
  in
  let before = pos "__before__" and after = pos "__after__" and replace = pos "__replace__" in
  let feats = client.cl_features in
  let positioned =
    if before <> None || after <> None || replace <> None then begin
      let rec go acc = function
        | [] -> None
        | ef :: rest ->
          let n = ef.f_name in
          if before = Some n then Some (List.rev_append acc (f :: ef :: rest))
          else if after = Some n then Some (List.rev_append acc (ef :: f :: rest))
          else if replace = Some n then Some (List.rev_append acc (f :: rest))
          else go (ef :: acc) rest
      in go [] feats
    end else None
  in
  match positioned with
  | Some l -> client.cl_features <- l
  | None -> client.cl_features <- feats @ [f]

let feature_init_util (ctx : ctx) (f : feature) : unit =
  let fname = f.f_name in
  let fopts = ref (empty_map ()) in
  (match getp ctx.c_options "feature" with
   | Map _ as feature_opts ->
     (match getp feature_opts fname with Map _ as fo -> fopts := fo | _ -> ())
   | _ -> ());
  if getp !fopts "active" = Bool true then f.f_init ctx !fopts

(* ----- prepare / param ----- *)

(* The API definition is authoritative: a POST-only or PATCH-based API
   exposes `update` as POST or PATCH, not the PUT the op name implies.
   Only fall back to the op-name convention when the point has no method. *)
let prepare_method_util (ctx : ctx) : string =
  match getp ctx.c_point "method" with
  | Str m when m <> "" -> String.uppercase_ascii m
  | _ ->
    match ctx.c_op.op_name with
    | "create" -> "POST" | "update" -> "PUT" | "load" -> "GET"
    | "list" -> "GET" | "remove" -> "DELETE" | "patch" -> "PATCH" | _ -> "GET"

let prepare_headers_util (ctx : ctx) : value =
  let options = client_options_map (cc ctx) in
  match getp options "headers" with
  | Noval -> empty_map ()
  | h -> (match clone h with Map _ as m -> m | _ -> empty_map ())

let param_util (ctx : ctx) (paramdef : value) : value =
  let point = ctx.c_point and spec = ctx.c_spec in
  let mtch = ctx.c_match and reqmatch = ctx.c_reqmatch
  and data = ctx.c_data and reqdata = ctx.c_reqdata in
  let pt = typify paramdef in
  let key =
    if (t_string land pt) > 0 then (match paramdef with Str s -> s | _ -> "")
    else (match getp paramdef "name" with Str s -> s | _ -> "")
  in
  let akey =
    match to_map (getp point "alias") with
    | Map _ as alias -> (match getp alias key with Str s -> s | _ -> "")
    | _ -> ""
  in
  let v = ref (getp reqmatch key) in
  if is_noval !v then v := getp mtch key;
  if is_noval !v && akey <> "" then begin
    (match spec with Some sp -> setp sp.sp_alias akey (Str key) | None -> ());
    v := getp reqmatch akey
  end;
  if is_noval !v then v := getp reqdata key;
  if is_noval !v then v := getp data key;
  if is_noval !v && akey <> "" then begin
    v := getp reqdata akey;
    if is_noval !v then v := getp data akey
  end;
  !v

let prepare_params_util (ctx : ctx) : value =
  let params =
    match getp ctx.c_point "args" with
    | Map _ as args -> (match getp args "params" with List r -> !r | _ -> [])
    | _ -> []
  in
  let out = empty_map () in
  List.iter (fun pd ->
      let v = (cu ctx).u_param ctx pd in
      if not (is_noval v) then
        (match pd with
         | Map _ -> (match getp pd "name" with Str name when name <> "" -> setp out name v | _ -> ())
         | _ -> ())) params;
  out

let prepare_path_util (ctx : ctx) : string =
  let parts = match getp ctx.c_point "parts" with List _ as l -> l | _ -> empty_list () in
  join ~sep:(Str "/") ~url:true parts

let prepare_query_util (ctx : ctx) : value =
  let reqmatch = match ctx.c_reqmatch with Map _ as m -> m | _ -> empty_map () in
  let params =
    match getp ctx.c_point "params" with List r -> !r | _ -> []
  in
  let contains_param s = List.exists (fun v -> match v with Str x -> x = s | _ -> false) params in
  let out = empty_map () in
  List.iter (fun k ->
      let v = getp reqmatch k in
      if not (is_noval v) && not (contains_param k) then setp out k v)
    (keysof reqmatch);
  out

let prepare_body_util (ctx : ctx) : value =
  if ctx.c_op.op_input = "data" then (cu ctx).u_transform_request ctx else Noval

(* ---- graphql (transport) -------------------------------------------------
 *
 * GraphQL transport. API-INDEPENDENT: every GraphQL SDK this generator
 * produces uses this code unchanged. The API-specific part — which operations
 * exist and what each one's document is — is model data, computed once by
 * apidef and emitted into Config.
 *
 * Two jobs:
 *
 *   graphql_body_util   — build { query, variables } for a point, binding the
 *                         op's arguments to the document's declared variables.
 *
 *   graphql_errors_util — lift a GraphQL failure into an SDK error. GraphQL
 *                         reports failures as a top-level `errors` array under
 *                         HTTP 200, so the status-driven path in result_basic
 *                         never sees them. *)

(* Content type every GraphQL-over-HTTP request uses. *)
let graphql_content_type = "application/json"

(* Map a GraphQL error to the same error codes the HTTP path produces, so a
 * caller handles auth or rate limiting identically on both transports.
 * Servers put the machine-readable code in `extensions.code`; Linear-style
 * APIs use `extensions.type`. *)
let graphql_error_code (gqlerr : value) : string =
  let ext = getp gqlerr "extensions" in
  let code = get_str_d ext "code" "" in
  let code = if code = "" then get_str_d ext "type" "" else code in
  let raw = String.uppercase_ascii code in
  if substr_contains raw "AUTH" || substr_contains raw "FORBIDDEN"
     || substr_contains raw "UNAUTHENTICATED" then "request_auth"
  else if substr_contains raw "RATELIMIT" || substr_contains raw "RATE_LIMIT"
          || substr_contains raw "TOO_MANY" then "request_ratelimit"
  else if substr_contains raw "BAD_USER_INPUT" || substr_contains raw "VALIDATION"
          || substr_contains raw "INVALID" then "request_invalid"
  else "request_graphql"

(* Build the request body for a GraphQL point.
 *
 * Variables come from the op's own arguments: a named variable binds to the
 * like-named argument (`from`), and the input-object variable (empty `from`)
 * takes the request data as a whole — which is what makes a generated
 * create/update call look exactly like its REST equivalent. *)
let graphql_body_util (ctx : ctx) : value =
  match getp ctx.c_point "graphql" with
  | Map _ as gql ->
    (* reqmatch/reqdata hold the caller's arguments for THIS call; data/match
     * hold the entity's current state. Which pair depends on whether the op
     * takes match or data input. A named variable falls back to the current
     * state, so updating a loaded entity with just {title} still binds the
     * stored id the mutation requires. *)
    let datainput = ctx.c_op.op_input = "data" in
    let reqsrc = if datainput then ctx.c_reqdata else ctx.c_reqmatch in
    let datasrc = if datainput then ctx.c_data else ctx.c_match in
    let reqsrc = match reqsrc with Map _ as m -> m | _ -> empty_map () in
    let datasrc = match datasrc with Map _ as m -> m | _ -> empty_map () in
    let variables = empty_map () in
    let varlist = match getp gql "vars" with List r -> !r | _ -> [] in
    List.iter (fun spec ->
        match spec with
        | Map _ ->
          let name = get_str_d spec "name" "" in
          let from = get_str_d spec "from" "" in
          if name <> "" then begin
            if from = "" then begin
              (* The input object IS the request body. Strip the action
               * selector, which is an SDK-side point discriminator, not an
               * API field. *)
              let body = empty_map () in
              List.iter (fun k ->
                  if k <> "$action" then setp body k (getp reqsrc k))
                (keysof reqsrc);
              setp variables name body
            end
            else
              (* Only send variables the caller actually supplied: sending an
               * explicit null would clear a field on many APIs. *)
              let v = getp reqsrc from in
              let v = if is_nullish v then getp datasrc from else v in
              if not (is_nullish v) then setp variables name v
          end
        | _ -> ())
      varlist;
    jo [("query", getp gql "doc"); ("variables", variables)]
  | _ -> Noval

(* Inspect a decoded GraphQL response body and record a failure when the
 * server reported one. Returns true when an error was recorded.
 *
 * Partial data (`data` alongside `errors`) is treated as failure: the REST
 * surface has no partial-success concept, and silently returning half an
 * object would be worse than failing. *)
let graphql_errors_util (ctx : ctx) : bool =
  match ctx.c_result with
  | None -> false
  | Some result ->
    if get_str_d ctx.c_point "kind" "" <> "graphql" then false
    else
      let errors = match getp result.rt_body "errors" with List r -> !r | _ -> [] in
      let count = List.length errors in
      if count = 0 then false
      else begin
        let first = List.hd errors in
        let msg = get_str_d first "message" "" in
        let msg = if msg = "" then "graphql error" else msg in
        let msg =
          if 1 < count then msg ^ " (+" ^ string_of_int (count - 1) ^ " more)"
          else msg in
        result.rt_err <-
          Some (ctx_make_error ctx (graphql_error_code first) ("graphql: " ^ msg));
        result.rt_ok <- false;
        true
      end

let prepare_auth_util (ctx : ctx) : (spec option * sdk_error option) =
  match ctx.c_spec with
  | None -> (None, Some (ctx_make_error ctx "auth_no_spec" "Expected context spec property to be defined."))
  | Some spec ->
    let headers = spec.sp_headers in
    let options = client_options_map (cc ctx) in
    (match getp options "auth" with
     | Noval | Null -> ignore (delprop headers (Str "authorization")); (Some spec, None)
     | _ ->
       let apikey = getprop ~alt:(Str "__NOTFOUND__") options (Str "apikey") in
       let is_notfound = (match apikey with Str "__NOTFOUND__" -> true | _ -> false) in
       if is_notfound || is_noval apikey || apikey = Str "" then
         ignore (delprop headers (Str "authorization"))
       else begin
         let auth_prefix = match getpath_s options "auth.prefix" with Str s -> s | _ -> "" in
         let apikey_val = match apikey with Str s -> s | _ -> "" in
         let authval = if auth_prefix <> "" then auth_prefix ^ " " ^ apikey_val else apikey_val in
         setp headers "authorization" (Str authval)
       end;
       (Some spec, None))

(* ----- transforms / result helpers ----- *)

let transform_request_util (ctx : ctx) : value =
  (match ctx.c_spec with Some s -> s.sp_step <- "reqform" | None -> ());
  match to_map (getp ctx.c_point "transform") with
  | Map _ as tr ->
    (match getp tr "req" with
     | Noval -> ctx.c_reqdata
     | reqform -> transform (jo [("reqdata", ctx.c_reqdata)]) reqform)
  | _ -> ctx.c_reqdata

let transform_response_util (ctx : ctx) : value =
  (match ctx.c_spec with Some s -> s.sp_step <- "resform" | None -> ());
  match ctx.c_result with
  | None -> Noval
  | Some result ->
    if not result.rt_ok then Noval
    else
      (match to_map (getp ctx.c_point "transform") with
       | Map _ as tr ->
         (match getp tr "res" with
          | Noval -> Noval
          | resform ->
            let input = jo [
              ("ok", Bool result.rt_ok); ("status", vint_of result.rt_status);
              ("statusText", Str result.rt_status_text); ("headers", result.rt_headers);
              ("body", result.rt_body);
              ("err", (match result.rt_err with Some e -> jo [("message", Str e.err_msg)] | None -> Noval));
              ("resdata", result.rt_resdata); ("resmatch", result.rt_resmatch) ] in
            let resdata = transform input resform in
            result.rt_resdata <- resdata; resdata)
       | _ -> Noval)

let result_basic_util (ctx : ctx) : unit =
  match ctx.c_response, ctx.c_result with
  | Some response, Some result ->
    result.rt_status <- response.rs_status;
    result.rt_status_text <- response.rs_status_text;
    if result.rt_status >= 400 then begin
      let msg = "request: " ^ string_of_int result.rt_status ^ ": " ^ result.rt_status_text in
      (match result.rt_err with
       | Some prev -> result.rt_err <- Some (ctx_make_error ctx "request_status" (prev.err_msg ^ ": " ^ msg))
       | None -> result.rt_err <- Some (ctx_make_error ctx "request_status" msg))
    end else (match response.rs_err with Some e -> result.rt_err <- Some e | None -> ())
  | _ -> ()

let result_body_util (ctx : ctx) : unit =
  match ctx.c_response, ctx.c_result with
  | Some response, Some result ->
    if is_callable response.rs_json && not (is_noval response.rs_body) then
      result.rt_body <- call_json response.rs_json
  | _ -> ()

let result_headers_util (ctx : ctx) : unit =
  match ctx.c_result with
  | None -> ()
  | Some result ->
    (match ctx.c_response with
     | Some response -> (match response.rs_headers with Map _ as m -> result.rt_headers <- m | _ -> result.rt_headers <- empty_map ())
     | None -> result.rt_headers <- empty_map ())

(* ----- make_* pipeline stages ----- *)

let make_point_util (ctx : ctx) : (value * sdk_error option) =
  match Hashtbl.find_opt ctx.c_out "point" with
  | Some (OErr e) -> (Noval, Some e)
  | Some (OPoint p) -> ctx.c_point <- p; (p, None)
  | _ ->
    let op = ctx.c_op in
    let options = ctx.c_options in
    let allow_op = match getpath_s options "allow.op" with Str s -> s | _ -> "" in
    if not (substr_contains allow_op op.op_name) then
      (Noval, Some (ctx_make_error ctx "point_op_allow"
        ("Operation \"" ^ op.op_name ^ "\" not allowed by SDK option allow.op value: \"" ^ allow_op ^ "\"")))
    else begin
      let points = match op.op_points with List r -> !r | _ -> [] in
      match points with
      | [] -> (Noval, Some (ctx_make_error ctx "point_no_points"
          ("Operation \"" ^ op.op_name ^ "\" has no endpoint definitions.")))
      | [single] -> ctx.c_point <- single; (ctx.c_point, None)
      | _ ->
        let reqselector, selector =
          if op.op_input = "data" then ctx.c_reqdata, ctx.c_data
          else ctx.c_reqmatch, ctx.c_match in
        let chosen = ref Noval in
        let matched = ref false in
        let n = List.length points in
        let arr = Array.of_list points in
        let i = ref 0 and stop = ref false in
        while not !stop && !i < n do
          let point = arr.(!i) in
          let select_def = to_map (getp point "select") in
          let found = ref true in
          (match select_def with
           | Map _ ->
             (match getp select_def "exist" with
              | List r ->
                List.iter (fun ek ->
                    if !found then begin
                      let existkey = vstring ek in
                      let rv = getp reqselector existkey and sv = getp selector existkey in
                      if is_noval rv && is_noval sv then found := false
                    end) !r
              | _ -> ())
           | _ -> ());
          if !found then begin
            let req_action = getp reqselector "$action" in
            let select_action = getp select_def "$action" in
            if req_action <> select_action then found := false
          end;
          if !found then begin chosen := point; matched := true; stop := true end
          else incr i
        done;
        (* select.exist can list more than the params needed to pick a point
           (for /boards/{id} it is Trello's 17 optional query-includes), so a
           plain {id} call matches NOTHING. Fall back to the entity's own
           route rather than whichever point came last. *)
        if not !matched then begin
          (* A request naming an action reaches here only because that
             action's own point failed its exist test, so it is unbuildable
             whatever we pick. Refuse it BEFORE choosing a fallback: the guard
             below compares the chosen point's $action and would wave the
             request through whenever the fallback lands on the action point
             itself. *)
          let unmatched_action = getp reqselector "$action" in
          if not (is_noval unmatched_action) then
            raise (Sdk_error_exc (ctx_make_error ctx "point_action_invalid"
              ("Operation \"" ^ op.op_name ^ "\" action \"" ^ (stringify unmatched_action) ^ "\" is not valid.")));
          (* A terminal parameter marks a record route (/boards/{id}); a
             cross-reference ends in the relationship's name
             (/posts/{id}/author). Failing that, the shallower path wins. The
             same rule runs at generation time, in helpers/opShape.ts — both
             sides must move together. *)
          let parts_len p =
            match getp p "parts" with List r -> List.length !r | _ -> 0 in
          let terminal_param p =
            match getp p "parts" with
            | List r ->
              (match List.rev !r with
               | last :: _ ->
                 let s = vstring last in
                 String.length s > 0 && s.[0] = '{'
               | [] -> false)
            | _ -> false in
          chosen := arr.(0);
          Array.iter (fun cand ->
              let ct = terminal_param cand and bt = terminal_param !chosen in
              if ct <> bt then (if ct then chosen := cand)
              else if parts_len cand < parts_len !chosen then chosen := cand) arr
        end;
        let req_action = getp reqselector "$action" in
        if not (is_noval req_action) && not (is_noval !chosen) then begin
          let point_select = to_map (getp !chosen "select") in
          let point_action = getp point_select "$action" in
          if req_action <> point_action then
            raise (Sdk_error_exc (ctx_make_error ctx "point_action_invalid"
              ("Operation \"" ^ op.op_name ^ "\" action \"" ^ (match stringify req_action with s -> s) ^ "\" is not valid.")))
        end;
        ctx.c_point <- !chosen;
        (ctx.c_point, None)
    end

let make_spec_util (ctx : ctx) : (spec option * sdk_error option) =
  match Hashtbl.find_opt ctx.c_out "spec" with
  | Some (OErr e) -> (None, Some e)
  | Some (OSpec s) -> ctx.c_spec <- Some s; (Some s, None)
  | _ ->
    let options = ctx.c_options in
    let u = cu ctx in
    let base = match getp options "base" with Str s -> s | _ -> "" in
    let prefix = match getp options "prefix" with Str s -> s | _ -> "" in
    let suffix = match getp options "suffix" with Str s -> s | _ -> "" in
    let parts = match getp ctx.c_point "parts" with List _ as l -> l | _ -> empty_list () in
    let sp = new_spec (jo [("base", Str base); ("prefix", Str prefix);
                           ("parts", parts); ("suffix", Str suffix); ("step", Str "start")]) in
    ctx.c_spec <- Some sp;
    sp.sp_method <- u.u_prepare_method ctx;
    let allow_method = match getpath_s options "allow.method" with Str s -> s | _ -> "" in
    if not (substr_contains allow_method sp.sp_method) then
      (None, Some (ctx_make_error ctx "spec_method_allow"
        ("Method \"" ^ sp.sp_method ^ "\" not allowed by SDK option allow.method value: \"" ^ allow_method ^ "\"")))
    else begin
      sp.sp_params <- u.u_prepare_params ctx;
      sp.sp_query <- u.u_prepare_query ctx;
      sp.sp_headers <- u.u_prepare_headers ctx;
      if get_str_d ctx.c_point "kind" "" = "graphql" then begin
        (* GraphQL addresses one endpoint: no path parts, no query string, and
         * the body carries the operation. prepare_body is skipped
         * deliberately — it only emits a body for data-input ops, whereas
         * every GraphQL op posts one, including load/list/remove. *)
        sp.sp_body <- u.u_graphql_body ctx;
        sp.sp_path <- "";
        (* prepare_query already copied the op's match arguments into the query
         * string. Those same values are bound as operation variables, so
         * leaving them would send /graphql?id=i1. *)
        sp.sp_query <- empty_map ();
        setp sp.sp_headers "content-type" (Str graphql_content_type)
      end
      else begin
        sp.sp_body <- u.u_prepare_body ctx;
        sp.sp_path <- u.u_prepare_path ctx
      end;
      (match ctx.c_ctrl.ctrl_explain with Map _ -> setp ctx.c_ctrl.ctrl_explain "spec" (spec_to_value sp) | _ -> ());
      match u.u_prepare_auth ctx with
      | (_, Some err) -> (None, Some err)
      | (Some spec2, None) -> ctx.c_spec <- Some spec2; (Some spec2, None)
      | (None, None) -> (Some sp, None)
    end

let make_url_util (ctx : ctx) : (string * sdk_error option) =
  match ctx.c_spec, ctx.c_result with
  | None, _ -> ("", Some (ctx_make_error ctx "url_no_spec" "Expected context spec property to be defined."))
  | _, None -> ("", Some (ctx_make_error ctx "url_no_result" "Expected context result property to be defined."))
  | Some spec, Some result ->
    let url = ref (join ~sep:(Str "/") ~url:true (ja [Str spec.sp_base; Str spec.sp_prefix; Str spec.sp_path; Str spec.sp_suffix])) in
    let resmatch = empty_map () in
    List.iter (fun key ->
        let v = getp spec.sp_params key in
        if not (is_noval v) then begin
          let encoded = escurl_s (vstring v) in
          url := str_replace_all !url ("{" ^ key ^ "}") encoded;
          setp resmatch key v
        end) (keysof spec.sp_params);
    let qsep = ref "?" in
    List.iter (fun key ->
        let v = getp spec.sp_query key in
        if not (is_noval v) then begin
          url := !url ^ !qsep ^ escurl_s key ^ "=" ^ escurl_s (vstring v);
          qsep := "&";
          setp resmatch key v
        end) (keysof spec.sp_query);
    result.rt_resmatch <- resmatch;
    (!url, None)

let make_fetch_def_util (ctx : ctx) : (value * sdk_error option) =
  match ctx.c_spec with
  | None -> (Noval, Some (ctx_make_error ctx "fetchdef_no_spec" "Expected context spec property to be defined."))
  | Some spec ->
    if ctx.c_result = None then ctx.c_result <- Some (new_result (empty_map ()));
    spec.sp_step <- "prepare";
    (match (cu ctx).u_make_url ctx with
     | (_, Some err) -> (Noval, Some err)
     | (url, None) ->
       spec.sp_url <- url;
       let fetchdef = jo [("url", Str url); ("method", Str spec.sp_method); ("headers", spec.sp_headers)] in
       (match spec.sp_body with
        | Noval -> ()
        | Map _ -> setp fetchdef "body" (Str (jsonify spec.sp_body))
        | b -> setp fetchdef "body" b);
       (fetchdef, None))

let make_request_util (ctx : ctx) : (response option * sdk_error option) =
  match Hashtbl.find_opt ctx.c_out "request" with
  | Some (OErr e) -> (None, Some e)
  | Some (OResponse r) -> (Some r, None)
  | _ ->
    let u = cu ctx in
    let response = ref (new_response (empty_map ())) in
    let result = new_result (empty_map ()) in
    ctx.c_result <- Some result;
    (match ctx.c_spec with
     | None -> (None, Some (ctx_make_error ctx "request_no_spec" "Expected context spec property to be defined."))
     | Some spec ->
       (match u.u_make_fetch_def ctx with
        | (_, Some err) ->
          (!response).rs_err <- Some err;
          ctx.c_response <- Some !response;
          spec.sp_step <- "postrequest";
          (Some !response, None)
        | (fetchdef, None) ->
          (match ctx.c_ctrl.ctrl_explain with Map _ -> setp ctx.c_ctrl.ctrl_explain "fetchdef" fetchdef | _ -> ());
          spec.sp_step <- "prerequest";
          let url = match getp fetchdef "url" with Str s -> s | _ -> "" in
          let (fetched, fetch_err) = u.u_fetcher ctx url fetchdef in
          (match fetch_err with
           | Some fe -> (!response).rs_err <- Some fe
           | None ->
             if is_noval fetched || fetched = Null then begin
               response := new_response (empty_map ());
               (!response).rs_err <- Some (ctx_make_error ctx "request_no_response" "response: undefined")
             end else (match fetched with
               | Map _ -> response := new_response fetched
               | _ -> (!response).rs_err <- Some (ctx_make_error ctx "request_invalid_response" "response: invalid type")));
          spec.sp_step <- "postrequest";
          ctx.c_response <- Some !response;
          (Some !response, None)))

let make_response_util (ctx : ctx) : (response option * sdk_error option) =
  match Hashtbl.find_opt ctx.c_out "response" with
  | Some (OErr e) -> (None, Some e)
  | Some (OResponse r) -> (Some r, None)
  | _ ->
    let u = cu ctx in
    (match ctx.c_spec with
     | None -> (None, Some (ctx_make_error ctx "response_no_spec" "Expected context spec property to be defined."))
     | Some spec ->
       (match ctx.c_response with
        | None -> (None, Some (ctx_make_error ctx "response_no_response" "Expected context response property to be defined."))
        | Some response ->
          (match ctx.c_result with
           | None -> (None, Some (ctx_make_error ctx "response_no_result" "Expected context result property to be defined."))
           | Some result ->
             spec.sp_step <- "response";
             u.u_result_basic ctx; u.u_result_headers ctx; u.u_result_body ctx;
             (* GraphQL reports failures as a top-level `errors` array under
              * HTTP 200, so result_basic's status check never sees them. Lift
              * them here, before the response transform tries to unwrap data
              * that is not there. *)
             ignore (u.u_graphql_errors ctx);
             ignore (u.u_transform_response ctx);
             if result.rt_err = None then result.rt_ok <- true;
             (match ctx.c_ctrl.ctrl_explain with Map _ -> setp ctx.c_ctrl.ctrl_explain "result" (result_to_value result) | _ -> ());
             (Some response, None))))

let make_result_util (ctx : ctx) : (result option * sdk_error option) =
  match Hashtbl.find_opt ctx.c_out "result" with
  | Some (OErr e) -> (None, Some e)
  | Some (OResult r) -> (Some r, None)
  | _ ->
    let u = cu ctx in
    let op = ctx.c_op in
    (match ctx.c_spec with
     | None -> (None, Some (ctx_make_error ctx "result_no_spec" "Expected context spec property to be defined."))
     | Some spec ->
       (match ctx.c_result with
        | None -> (None, Some (ctx_make_error ctx "result_no_result" "Expected context result property to be defined."))
        | Some result ->
          spec.sp_step <- "result";
          ignore (u.u_transform_response ctx);
          if op.op_name = "list" then begin
            let resdata = result.rt_resdata in
            result.rt_resdata <- empty_list ();
            (match resdata, ctx.c_entity with
             | List r, Some entity ->
               let entries = List.map (fun entry ->
                   let ent = entity.e_make () in
                   (match entry with Map _ -> ent.e_data_set entry | _ -> ());
                   entry) !r in
               result.rt_resdata <- lst entries
             | _ -> ())
          end;
          (match ctx.c_ctrl.ctrl_explain with Map _ -> setp ctx.c_ctrl.ctrl_explain "result" (result_to_value result) | _ -> ());
          (Some result, None)))

(* ----- fetcher (innermost transport) ----- *)

let fetcher_util (ctx : ctx) (fullurl : string) (fetchdef : value) : (value * sdk_error option) =
  let client = cc ctx in
  if client.cl_mode <> "live" then
    (Noval, Some (ctx_make_error ctx "fetch_mode_block"
      ("Request blocked by mode: \"" ^ client.cl_mode ^ "\" (URL was: \"" ^ fullurl ^ "\")")))
  else begin
    let options = client_options_map client in
    if getpath_s options "feature.test.active" = Bool true then
      (Noval, Some (ctx_make_error ctx "fetch_test_block"
        ("Request blocked as test feature is active (URL was: \"" ^ fullurl ^ "\")")))
    else
      let sys_fetch = getpath_s options "system.fetch" in
      match sys_fetch with
      | Func _ ->
        let out = call_vfn sys_fetch (ja [Str fullurl; fetchdef]) in
        (match get_str out "__err__" with
         | Some msg -> (Noval, Some (ctx_make_error ctx "fetch_system" msg))
         | None -> (out, None))
      | Noval | Null ->
        (* No live HTTP transport is bundled (dependency-free build); tests
         * run against the test-feature mock or a system.fetch injection. *)
        (Noval, Some (ctx_make_error ctx "fetch_no_transport"
          "No live HTTP transport in this build; provide options.system.fetch."))
      | _ -> (Noval, Some (ctx_make_error ctx "fetch_invalid" "system.fetch is not a valid function"))
  end

(* ------------------------------------------------------------------ *)
(* make_options                                                        *)
(* ------------------------------------------------------------------ *)

let opt_spec_value () : value =
  jo [
    ("apikey", Str "");
    ("base", Str "http://localhost:8000");
    ("prefix", Str "");
    ("suffix", Str "");
    ("auth", jo [("prefix", Str "")]);
    ("headers", jo [("`$CHILD`", Str "`$STRING`")]);
    ("allow", jo [("method", Str "GET,PUT,POST,PATCH,DELETE,OPTIONS");
                  ("op", Str "create,update,load,list,remove,command,direct,graphql")]);
    ("entity", jo [("`$CHILD`", jo [("`$OPEN`", Bool true); ("active", Bool false); ("alias", empty_map ())])]);
    ("feature", jo [("`$CHILD`", jo [("`$OPEN`", Bool true); ("active", Bool false)])]);
    ("utility", empty_map ());
    ("system", empty_map ());
    ("test", jo [("active", Bool false); ("entity", jo [("`$OPEN`", Bool true)])]);
    ("clean", jo [("keys", Str "key,token,id")]);
      (* Server-variable values for a templated base URL (OpenAPI server
       * variables): {name} placeholders in "base" are substituted from this
       * map at construction. Spec defaults arrive via the generated config;
       * user values override them. Mirrors go's make_options optspec. *)
      ("server", jo [("`$CHILD`", Str "")]);
  ]

let make_options_util (ctx : ctx) : value =
  let options = match ctx.c_options with Noval -> empty_map () | v -> v in
  (match getp options "utility" with
   | Map _ as custom_utils ->
     (match ctx.c_utility with
      | Some u -> List.iter (fun k -> setp u.u_custom k (getp custom_utils k)) (keysof custom_utils)
      | None -> ())
   | _ -> ());
  let opts = match clone options with Map _ as m -> m | _ -> empty_map () in
  (* Feature add-order. options.feature may be given as an ordered LIST of
     {name; active; ...opts} entries (list position = add order) or a
     {name => {opts}} map. Normalize a list to a map (so merge/validate/init
     are unchanged) and remember the explicit order; a map defaults to
     test-first so the `test` mock transport is the base of the wrapper chain. *)
  let explicit_order =
    match getp opts "feature" with
    | List r ->
      let fmap = empty_map () in
      let order = List.filter_map (fun entry ->
          match entry with
          | Map _ ->
            (match getp entry "name" with
             | Str nm ->
               let fopts = clone entry in
               ignore (delprop fopts (Str "name"));
               setp fmap nm fopts;
               Some nm
             | _ -> None)
          | _ -> None) !r in
      setp opts "feature" fmap;
      Some order
    | _ -> None in
  let config = match ctx.c_config with Map _ as m -> m | _ -> empty_map () in
  let cfgopts = match to_map (getp config "options") with Map _ as m -> m | _ -> empty_map () in
  let optspec = opt_spec_value () in
  let sys_fetch = getpath_s opts "system.fetch" in
  let merged = merge (ja [empty_map (); cfgopts; opts]) in
  let validated = validate merged optspec in
  let opts = match validated with Map _ as m -> m | _ -> empty_map () in
  (* Resolve a templated base URL (e.g. https://{tenant_id}.hanko.io).
     Every placeholder must resolve to a non-empty value: from options.server
     (user), else the Config default. A placeholder that resolves to "" is a
     construction ERROR in live mode - the URL cannot work - but in test mode
     substitutes the deterministic value "test-<name>" so offline tests need no
     configuration. The SDK constructor has no error return, so a missing
     required variable RAISES: construction-time misconfiguration.

     Scanned by hand: a placeholder is `{` followed by [A-Za-z0-9_]+ and `}`;
     anything else is literal text, so a stray brace is left alone. *)
  (match getp opts "base" with
   | Str base when String.contains base '{' ->
     let is_true v = match v with Bool b -> b | _ -> false in
     let testmode =
       is_true (getpath_s opts "test.active")
       || is_true (getpath_s opts "feature.test.active") in
     let server = match getp opts "server" with Map _ as m -> m | _ -> empty_map () in
     let sdkname =
       match getpath_s config "main.name" with Str s when s <> "" -> s | _ -> "SDK" in
     let namechar c =
       (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
       || (c >= '0' && c <= '9') || c = '_' in
     let buf = Buffer.create (String.length base) in
     let n = String.length base in
     let i = ref 0 in
     while !i < n do
       if base.[!i] <> '{' then begin
         Buffer.add_char buf base.[!i];
         incr i
       end else begin
         let j = ref (!i + 1) in
         while !j < n && namechar base.[!j] do incr j done;
         if !j >= n || base.[!j] <> '}' || !j = !i + 1 then begin
           Buffer.add_char buf base.[!i];
           incr i
         end else begin
           let name = String.sub base (!i + 1) (!j - !i - 1) in
           let value = match getp server name with Str s -> s | _ -> "" in
           if value <> "" then Buffer.add_string buf value
           else if testmode then Buffer.add_string buf ("test-" ^ name)
           else
             raise (Sdk_error_exc (ctx_make_error ctx "server_var_required"
               (sdkname ^ ": the server variable '" ^ name ^ "' is required: the API "
                ^ "base URL is '" ^ base ^ "' - pass ~server:[(\"" ^ name
                ^ "\", \"...\")] in the SDK options")));
           i := !j + 1
         end
       end
     done;
     setp opts "base" (Str (Buffer.contents buf))
   | _ -> ());
  (if not (is_noval sys_fetch) then
     match getp opts "system" with
     | Map _ as sys -> setp sys "fetch" sys_fetch
     | _ -> setp opts "system" (jo [("fetch", sys_fetch)]));
  let clean_keys = match getpath_s opts "clean.keys" with Str s -> s | _ -> "key,token,id" in
  let parts = List.filter_map (fun p -> let t = String.trim p in if t = "" then None else Some (escre_s t))
      (String.split_on_char ',' clean_keys) in
  let keyre = String.concat "|" parts in
  (* Resolve the feature add-order: an explicit list order (above) wins;
     otherwise order the map test-first, then the remaining names sorted, so
     the outcome is deterministic and `test` is always the base transport. *)
  let feature_order =
    match explicit_order with
    | Some ord -> ord
    | None ->
      let fmap = match getp opts "feature" with Map _ as m -> m | _ -> empty_map () in
      let names = keysof fmap in
      if List.mem "test" names
      then "test" :: List.filter (fun n -> n <> "test") names
      else names in
  let derived = jo [("clean", empty_map ())] in
  if keyre <> "" then setp derived "clean" (jo [("keyre", Str keyre)]);
  setp derived "featureorder" (ja (List.map (fun s -> Str s) feature_order));
  setp opts "__derived__" derived;
  opts

(* ------------------------------------------------------------------ *)
(* struct_api exposure (utility.struct)                                *)
(* ------------------------------------------------------------------ *)

let struct_api_instance : struct_api = {
  s_getprop = (fun v k -> getprop v k);
  s_setprop = (fun p k v -> setprop p k v);
  s_getpath = (fun store path -> getpath store path);
  s_setpath = (fun store path v -> setpath store path v);
  s_getelem = (fun v k -> getelem v k);
  s_haskey = (fun v k -> haskey v k);
  s_clone = clone;
  s_merge = (fun l -> merge (lst l));
  s_items = items;
  s_keysof = keysof;
  s_size = size;
  s_isempty = isempty;
  s_isnode = isnode;
  s_ismap = ismap;
  s_islist = islist;
  s_stringify = (fun v -> stringify v);
  s_jsonify = (fun v -> jsonify v);
  s_escurl = (fun v -> match escurl v with Str s -> s | _ -> "");
  s_escre = (fun v -> match escre v with Str s -> s | _ -> "");
  s_transform = (fun d s -> transform d s);
  s_validate = (fun d s -> validate d s);
  s_select = (fun c q -> select c q);
}

(* ------------------------------------------------------------------ *)
(* utility construction + registration                                 *)
(* ------------------------------------------------------------------ *)

let new_utility () : utility =
  {
    u_custom = empty_map ();
    u_struct = struct_api_instance;
    u_fetcher = fetcher_util;
    u_clean = clean_util;
    u_done = done_util;
    u_make_error = make_error_util;
    u_feature_add = feature_add_util;
    u_feature_hook = feature_hook_util;
    u_feature_init = feature_init_util;
    u_make_fetch_def = make_fetch_def_util;
    u_make_context = make_context_impl;
    u_make_options = make_options_util;
    u_make_request = make_request_util;
    u_make_response = make_response_util;
    u_make_result = make_result_util;
    u_make_point = make_point_util;
    u_make_spec = make_spec_util;
    u_make_url = make_url_util;
    u_param = param_util;
    u_prepare_auth = prepare_auth_util;
    u_prepare_body = prepare_body_util;
    u_prepare_headers = prepare_headers_util;
    u_prepare_method = prepare_method_util;
    u_prepare_params = prepare_params_util;
    u_prepare_path = prepare_path_util;
    u_prepare_query = prepare_query_util;
    u_graphql_body = graphql_body_util;
    u_graphql_errors = graphql_errors_util;
    u_result_basic = result_basic_util;
    u_result_body = result_body_util;
    u_result_headers = result_headers_util;
    u_transform_request = transform_request_util;
    u_transform_response = transform_response_util;
  }

(* register: rebind every util field (idempotent — new_utility already sets
 * them; kept for parity with the py registrar and to allow re-wiring). *)
let register (u : utility) : unit =
  u.u_fetcher <- fetcher_util;
  u.u_clean <- clean_util;
  u.u_done <- done_util;
  u.u_make_error <- make_error_util;
  u.u_feature_add <- feature_add_util;
  u.u_feature_hook <- feature_hook_util;
  u.u_feature_init <- feature_init_util;
  u.u_make_fetch_def <- make_fetch_def_util;
  u.u_make_context <- make_context_impl;
  u.u_make_options <- make_options_util;
  u.u_make_request <- make_request_util;
  u.u_make_response <- make_response_util;
  u.u_make_result <- make_result_util;
  u.u_make_point <- make_point_util;
  u.u_make_spec <- make_spec_util;
  u.u_make_url <- make_url_util;
  u.u_param <- param_util;
  u.u_prepare_auth <- prepare_auth_util;
  u.u_prepare_body <- prepare_body_util;
  u.u_prepare_headers <- prepare_headers_util;
  u.u_prepare_method <- prepare_method_util;
  u.u_prepare_params <- prepare_params_util;
  u.u_prepare_path <- prepare_path_util;
  u.u_prepare_query <- prepare_query_util;
  u.u_graphql_body <- graphql_body_util;
  u.u_graphql_errors <- graphql_errors_util;
  u.u_result_basic <- result_basic_util;
  u.u_result_body <- result_body_util;
  u.u_result_headers <- result_headers_util;
  u.u_transform_request <- transform_request_util;
  u.u_transform_response <- transform_response_util

let copy_utility (src : utility) : utility =
  let u = new_utility () in
  u.u_fetcher <- src.u_fetcher;
  u.u_struct <- src.u_struct;
  let custom = empty_map () in
  (match src.u_custom with Map _ -> List.iter (fun k -> setp custom k (getp src.u_custom k)) (keysof src.u_custom) | _ -> ());
  u.u_custom <- custom;
  u
