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

(* Whether a comma-separated allow option names the item: whole names, any case. *)
let allow_list_has (names : value) (item : string) : bool =
  match names with
  | Str list when item <> "" ->
    let want = String.uppercase_ascii item in
    List.exists (fun name -> String.uppercase_ascii (String.trim name) = want)
      (String.split_on_char ',' list)
  | _ -> false

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
    sp_url = gs "url" ""; sp_path = gs "path" "";
    sp_authquery = [] }

let new_response (m : value) : response =
  { rs_status = (match getp m "status" with Num n -> int_of_float n | _ -> -1);
    rs_status_text = (match getp m "statusText" with Str s -> s | _ -> "");
    rs_headers = getp m "headers";
    rs_json = (match getp m "json" with Func _ as f -> f | _ -> Noval);
    rs_body = getp m "body";
    rs_err = None;
    rs_unreadable = (getp m "unreadable" = Bool true) }

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

(* Every request racing to build this Operation gets the one stored first. *)
let rec store_op (opmap : operation OpMap.t Atomic.t) (key : string) (op : operation) : operation =
  let seen = Atomic.get opmap in
  match OpMap.find_opt key seen with
  | Some stored -> stored
  | None ->
    if Atomic.compare_and_set opmap seen (OpMap.add key op seen) then op
    else store_op opmap key op

let resolve_op (ctx : ctx) (opname : string) : operation =
  let entname = match ctx.c_entity with Some e -> e.e_name | None -> "_" in
  let cache_key = entname ^ ":" ^ opname in
  match OpMap.find_opt cache_key (Atomic.get ctx.c_opmap) with
  | Some op -> op
  | None ->
    if opname = "" then new_operation (empty_map ())
    else begin
      let opcfg = getpath_s ctx.c_config ("entity." ^ entname ^ ".op." ^ opname) in
      let inpt = if opname = "update" || opname = "create" || opname = "patch" then "data" else "match" in
      let points =
        match to_map opcfg with
        | Map _ -> (match getp opcfg "points" with List _ as l -> l | _ -> empty_list ())
        | _ -> empty_list ()
      in
      let op = new_operation
          (jo [("entity", Str entname); ("name", Str opname);
               ("input", Str inpt); ("points", points)]) in
      store_op ctx.c_opmap cache_key op
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
    | _ -> (match basectx with
        | Some b when cs.cs_opname = None -> b.c_ctrl
        | _ -> new_control ())
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
    | None -> (match basectx with Some b -> b.c_opmap | None -> Atomic.make OpMap.empty) in
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

(* ----- clean -----
 * Everything that leaves the pipeline passes through clean; inside it data
 * stays raw, so a hook can still read the header it must add to. See
 * docs/explanation/secret-redaction.md. *)

let clean_maxdepth = 32
let clean_circular = "[circular]"
let clean_drop = Sentinel "clean_drop"

let normkey (k : string) : string =
  let b = Buffer.create (String.length k) in
  String.iter (fun c -> match c with
      | '-' | '_' -> ()
      | c -> Buffer.add_char b (Char.lowercase_ascii c)) k;
  Buffer.contents b

let split_commas (s : string) : string list =
  List.filter (fun x -> x <> "") (List.map String.trim (String.split_on_char ',' s))

let splitkeys (v : value) : string list =
  match v with
  | Str s -> List.filter (fun x -> x <> "") (List.map normkey (split_commas s))
  | _ -> []

let splitvalues (v : value) : string list =
  match v with
  | List r -> List.filter_map (function Str s -> Some s | _ -> None) !r
  | Str s -> split_commas s
  | _ -> []

let count_opt (v : value) (dflt : int) : int =
  let n = match v with
    | Num n -> Some n
    | Str s -> float_of_string_opt (String.trim s)
    | _ -> None in
  match n with Some n when n >= 0. -> int_of_float (Float.floor n) | _ -> dflt

(* The derived clean block: a struct map so it lives in options.__derived__
 * and its `values` list stays MUTABLE after make_options - features
 * register what they resolve later. *)
let make_clean_config (cleanopts : value) : value =
  jo [("active", Bool (getp cleanopts "active" <> Bool false));
      ("keys", ja (List.map (fun s -> Str s) (splitkeys (getp cleanopts "keys"))));
      ("values", empty_list ());
      ("mask", (match getp cleanopts "mask" with Str s -> Str s | _ -> Str "[redacted]"));
      ("hint", vint_of (count_opt (getp cleanopts "hint") 0));
      ("min", vint_of (max 1 (count_opt (getp cleanopts "min") 4)))]

(* A context without options (make_error accepts a bare one) still masks by
 * the schema defaults. *)
let clean_config (ctx : ctx) : value =
  match getpath_s ctx.c_options "__derived__.clean" with
  | Map _ as m -> m
  | _ -> make_clean_config (getp (Sdk_schema.opt_spec_value ()) "clean")

let str_values (v : value) : string list =
  match v with List r -> List.filter_map (function Str s -> Some s | _ -> None) !r | _ -> []

(* The encoded forms a value travels in. *)
let clean_forms (value : string) : string list =
  let out = ref [] in
  let add s = if s <> "" && not (List.mem s !out) then out := !out @ [s] in
  add value;
  add (base64_encode value);
  add (escurl_s value);
  (let j = json_encode (Str value) in
   if String.length j >= 2 then add (String.sub j 1 (String.length j - 2)));
  !out

(* A registration reads the registry list and writes a new one, so requests
 * on other domains registering at once take turns, or one would be dropped.
 * Cleaning reads the list whole and needs no turn. *)
let clean_registering = Atomic.make false

let clean_add_util (ctx : ctx) (value : string) : unit =
  let cfg = clean_config ctx in
  let minlen = match getp cfg "min" with Num n -> int_of_float n | _ -> 4 in
  match getp cfg "values" with
  | List r when String.length value >= minlen ->
    while not (Atomic.compare_and_set clean_registering false true) do () done;
    Fun.protect ~finally:(fun () -> Atomic.set clean_registering false) (fun () ->
        let have = str_values (List r) in
        let add = List.filter (fun f -> String.length f >= minlen && not (List.mem f have))
            (clean_forms value) in
        (* Longest first, so a value is never masked by a substring of itself. *)
        if add <> [] then
          r := List.map (fun s -> Str s)
              (List.stable_sort (fun a b -> compare (String.length b) (String.length a)) (have @ add)))
  | _ -> ()

let mask_value (cfg : value) (value : string) : string =
  let hint = match getp cfg "hint" with Num n -> int_of_float n | _ -> 0 in
  let mask = match getp cfg "mask" with Str s -> s | _ -> "[redacted]" in
  if hint > 0 && String.length value > 2 * hint
  then mask ^ String.sub value (String.length value - hint) hint
  else mask

let clean_string (cfg : value) (text : string) : string =
  List.fold_left (fun out v ->
      if substr_contains out v then str_replace_all out v (mask_value cfg v) else out)
    text (str_values (getp cfg "values"))

let sensitive_key (cfg : value) (key : string option) : bool =
  match key with
  | None -> false
  | Some k ->
    (match int_of_string_opt k with
     | Some _ -> false
     | None ->
       let nk = normkey k in
       List.exists (fun sk -> substr_contains nk sk) (str_values (getp cfg "keys")))

(* Every scalar under a sensitive name, at any depth and of any shape: a
 * credential mistyped as a map or a number is still a credential, and the
 * validation error that rejects it quotes it. *)
let clean_add_sensitive (ctx : ctx) (v : value) : unit =
  let cfg = clean_config ctx in
  let rec walk v under depth seen =
    if depth < clean_maxdepth then begin
      match v with
      | Str s -> if under then clean_add_util ctx s
      | Num n -> if under then clean_add_util ctx (num_to_string n)
      | Map m when not (List.memq v seen) ->
        List.iter (fun (k, x) ->
            walk x (under || sensitive_key cfg (Some k)) (depth + 1) (v :: seen)) m.entries
      | List r when not (List.memq v seen) ->
        List.iter (fun x -> walk x under (depth + 1) (v :: seen)) !r
      | _ -> ()
    end in
  walk v false 0 []

(* A registered value used as a property name is masked like any other
 * string; names that mask alike take a counter, so none is lost. *)
let clean_name (cfg : value) (out : value) (key : string) : string =
  let name = clean_string cfg key in
  let taken = keysof out in
  if name = key || not (List.mem name taken) then name
  else
    let rec next i =
      let n = name ^ "#" ^ string_of_int i in
      if List.mem n taken then next (i + 1) else n in
    next 1

(* A masked plain-data COPY: functions dropped, cycles cut, and nothing
 * shared with the live value, whose spec must stay raw. *)
let rec clean_snapshot (cfg : value) (v : value) (key : string option) (depth : int) (seen : value list) : value =
  match v with
  | Noval | Null -> v
  | Str s -> Str (if sensitive_key cfg key then mask_value cfg s else clean_string cfg s)
  | Func _ | Sentinel _ -> clean_drop
  | Bool _ | Num _ -> if sensitive_key cfg key then getp cfg "mask" else v
  | Map _ | List _ ->
    if depth >= clean_maxdepth || List.memq v seen then Str clean_circular
    else if sensitive_key cfg key then getp cfg "mask"
    else begin
      let seen = v :: seen in
      match v with
      | Map m ->
        let out = empty_map () in
        List.iter (fun (k, x) ->
            match clean_snapshot cfg x (Some k) (depth + 1) seen with
            | Sentinel "clean_drop" -> ()
            | c -> setp out (clean_name cfg out k) c) m.entries;
        out
      | List r ->
        lst (List.map (fun x ->
            match clean_snapshot cfg x None (depth + 1) seen with
            | Sentinel "clean_drop" -> Null
            | c -> c) !r)
      | _ -> v
    end

let clean_util (ctx : ctx) (v : value) : value =
  let cfg = clean_config ctx in
  if getp cfg "active" = Bool false then v
  else match v with
    | Str s -> Str (clean_string cfg s)
    | _ -> (match clean_snapshot cfg v None 0 [] with Sentinel "clean_drop" -> Noval | c -> c)

(* An exception is immutable and of any shape, so one that never passed
 * through make_error (a hook's, a fetcher's) leaves as a cleaned copy: a
 * standard string-carrying one keeps its constructor, and any other whose
 * printed form quotes a registered value leaves as a Failure of that form,
 * cleaned. *)
let clean_exn (ctx : ctx) (e : exn) : exn =
  let cfg = clean_config ctx in
  if getp cfg "active" = Bool false then e
  else match e with
    | Sdk_error_exc er ->
      Sdk_error_exc { err_code = clean_string cfg er.err_code; err_msg = clean_string cfg er.err_msg;
                      err_result = clean_util ctx er.err_result; err_spec = clean_util ctx er.err_spec }
    | Failure msg -> Failure (clean_string cfg msg)
    | Invalid_argument msg -> Invalid_argument (clean_string cfg msg)
    | Struct_error msg -> Struct_error (clean_string cfg msg)
    | _ ->
      let text = Printexc.to_string e in
      let cleaned = clean_string cfg text in
      if cleaned = text then e else Failure cleaned

(* The explain map is the CALLER's, so it is cleaned in place: what they hold
 * after the call is the cleaned record. An omap is a mutable record, so its
 * entries are replaced under the value the caller still references. Its
 * result is a snapshot (result_to_value), never the live result, so err is
 * pruned from it in place. *)
let clean_explain (ctx : ctx) : unit =
  match ctx.c_ctrl.ctrl_explain with
  | Map m as ex ->
    (match (cu ctx).u_clean ctx ex with
     | Map cm when cm != m -> m.entries <- cm.entries
     | _ -> ());
    (match getp ex "result" with Map _ as r -> ignore (delprop r (Str "err")) | _ -> ())
  | _ -> ()

(* The serialised context leaves the pipeline (a logger, an error dump), so
 * it is the cleaned record; the live fields stay raw for the pipeline's use.
 * An OCaml record has no default print, so this is the SDK's own
 * serialisation of a context. *)
let ctx_to_value (ctx : ctx) : value =
  let record = jo [
      ("id", Str ctx.c_id);
      ("op", jo [("entity", Str ctx.c_op.op_entity); ("name", Str ctx.c_op.op_name);
                 ("input", Str ctx.c_op.op_input); ("points", ctx.c_op.op_points);
                 ("alias", ctx.c_op.op_alias)]);
      ("spec", (match ctx.c_spec with Some s -> spec_to_value s | None -> Noval));
      ("entity", (match ctx.c_entity with Some e -> Str e.e_name | None -> Noval));
      ("result", (match ctx.c_result with Some r -> result_to_value r | None -> Noval));
      ("response", (match ctx.c_response with
           | Some r -> jo [("status", vint_of r.rs_status); ("statusText", Str r.rs_status_text);
                           ("headers", r.rs_headers); ("body", r.rs_body)]
           | None -> Noval));
      ("meta", ctx.c_meta) ] in
  match ctx.c_utility with Some u -> u.u_clean ctx record | None -> clean_util ctx record

(* The client's own serialisation: its name and mode, never its options. *)
let client_to_value (client : sdk_client) : value =
  jo [("name", Str "Univec"); ("mode", Str client.cl_mode)]

(* The error prints as the cleaned pieces make_error attached. *)
let () =
  Printexc.register_printer (function
      | Sdk_error_exc e ->
        Some ("Sdk_error_exc " ^ jsonify ~flags:(jo [("indent", Num 0.)])
                (jo [("code", Str e.err_code); ("message", Str e.err_msg);
                     ("result", e.err_result); ("spec", e.err_spec)]))
      | _ -> None)

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
  clean_explain ctx;
  (match ctx.c_ctrl.ctrl_explain with
   | Map _ -> setp ctx.c_ctrl.ctrl_explain "err" (jo [("message", Str msg)])
   | _ -> ());
  (* Cleaned COPIES of the result and spec, never the live objects. *)
  (* A hook's own error supplies the code as well as the message. *)
  let code = match (cu ctx).u_clean ctx (Str err.err_code) with Str s -> s | _ -> err.err_code in
  let sdk_err = {
    err_code = code; err_msg = msg;
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
  clean_explain ctx;
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
    | "list" -> "GET" | "remove" -> "DELETE" | "patch" -> "PATCH"
    (* NO CATCH-ALL GET. The ts reference returns methodMap[key], which is
     * undefined for an op the map does not name — the request is then rejected
     * rather than silently issued. A `| _ -> "GET"` here turned every
     * unrecognised op into a GET, which is both a divergence from the corpus
     * (which expects no method for opname "bad") and the more dangerous of the
     * two behaviours: a mistyped or unsupported op quietly fetched. *)
    | _ -> ""

(* The arguments a point declares in one location, query or header, each as
 * (name, wire, value): the name it travels under and the value this call
 * passes in its match or else its data. Unlike a path parameter, the
 * entity's stored match and data never supply one. *)
let call_args (ctx : ctx) (kind : string) : (string * string * value) list =
  match getp (getp ctx.c_point "args") kind with
  | List r ->
    List.filter_map (fun ad ->
        match getp ad "name" with
        | Str name when name <> "" ->
          let wire = match getp ad "orig" with Str o when o <> "" -> o | _ -> name in
          let v = match getp ctx.c_reqmatch name with
            | Noval | Null -> getp ctx.c_reqdata name
            | v -> v
          in
          Some (name, wire, v)
        | _ -> None) !r
  | _ -> []

(* ---- media ----
 * The media types a point declares: `response` (the model's `rs`) for the
 * Accept header, and `body` (the model's `rb`) for the request body. *)

(* The data key holding a raw request body. Like `$action`, it can never be a
 * declared argument name. *)
let raw_body_key = "$body"

let is_json_media (media : string) : bool =
  let base = match String.index_opt media ';' with
    | Some i -> String.sub media 0 i
    | None -> media in
  let m = String.lowercase_ascii (String.trim base) in
  let n = String.length m in
  m = "application/json" || m = "text/json"
  || (n >= 5 && String.sub m (n - 5) 5 = "+json")

(* The declared JSON type alone, else every declared type in the model's
 * order; nothing when no success response declares a body. *)
let accept_of (point : value) : string option =
  let res = getp point "response" in
  match getp res "media" with
  | Str media when media <> "" ->
    (match getp res "kind" with
     | Str "json" -> Some media
     | _ ->
       let others = match getp res "alternatives" with
         | List r ->
           List.filter_map (fun alt -> match getp alt "media" with
               | Str m when m <> "" -> Some m
               | _ -> None) !r
         | _ -> [] in
       Some (String.concat ", " (media :: others)))
  | _ -> None

let is_raw_request (point : value) : bool =
  match getp (getp point "body") "kind" with Str "raw" -> true | _ -> false

let is_json_request (point : value) : bool =
  match getp (getp point "body") "kind" with Str "json" -> true | _ -> false

let has_media_header (headers : value) (name : string) : bool =
  List.exists (fun k -> String.lowercase_ascii k = name) (keysof headers)

(* A caller's accept wins. A declared request type replaces each JSON
 * content-type, the SDK default, and leaves any other the caller set. *)
let media_headers (point : value) (headers : value) : unit =
  (match accept_of point with
   | Some accept when not (has_media_header headers "accept") ->
     setp headers "accept" (Str accept)
   | _ -> ());
  let body = getp point "body" in
  match getp body "kind", getp body "media" with
  | Str ("raw" | "json"), Str media when media <> "" ->
    List.iter (fun k ->
        match getp headers k with
        | Str v when String.lowercase_ascii k = "content-type" && is_json_media v ->
          ignore (delprop headers (Str k))
        | _ -> ())
      (keysof headers);
    if not (has_media_header headers "content-type") then
      setp headers "content-type" (Str media)
  | _ -> ()

let raw_body (reqdata : value) : value = getp reqdata raw_body_key

(* The form style of a cookie parameter: a list repeats the name, a map sends
 * its own keys, and every value is percent-encoded. *)
let cookie_pair (wire : string) (v : value) : string =
  let esc x = escurl_s (stringify x) in
  let pairs = match v with
    | List items -> List.map (fun item -> wire ^ "=" ^ esc item) !items
    | Map _ -> List.map (fun k -> escurl_s k ^ "=" ^ esc (getp v k)) (keysof v)
    | _ -> [wire ^ "=" ^ esc v] in
  String.concat "; " pairs

let prepare_headers_util (ctx : ctx) : value =
  let options = client_options_map (cc ctx) in
  let out =
    match getp options "headers" with
    | Noval -> empty_map ()
    | h -> (match clone h with Map _ as m -> m | _ -> empty_map ())
  in
  media_headers ctx.c_point out;
  (* A header argument replaces a default of the same name, whatever its
   * case. *)
  List.iter (fun (_, wire, v) ->
      match v with
      | Noval | Null -> ()
      | v ->
        let key = String.lowercase_ascii wire in
        List.iter (fun k ->
            if String.lowercase_ascii k = key then ignore (delprop out (Str k)))
          (keysof out);
        setp out key (Str (stringify v)))
    (call_args ctx "header");
  (* A cookie argument travels in the cookie header, form serialized and
   * percent-encoded, replacing a cookie of the same name among those the
   * caller's headers already send. *)
  let sent = List.filter (fun (_, _, v) -> match v with Noval | Null -> false | _ -> true)
      (call_args ctx "cookie") in
  if sent <> [] then begin
    let names = List.concat (List.map (fun (_, wire, v) ->
        match v with Map _ -> List.map escurl_s (keysof v) | _ -> [wire]) sent) in
    let given = List.filter (fun k -> String.lowercase_ascii k = "cookie") (keysof out) in
    let kept = List.concat (List.map (fun k ->
        match getp out k with
        | Str s -> cookie_keep s names
        | _ -> []) given) in
    List.iter (fun k -> ignore (delprop out (Str k))) given;
    let pairs = List.filter_map (fun (_, wire, v) ->
        match cookie_pair wire v with "" -> None | pair -> Some pair) sent in
    if kept @ pairs <> [] then setp out "cookie" (Str (String.concat "; " (kept @ pairs)))
  end;
  out

(* The name a point gives a parameter in the call, if it renames it. *)
let param_alias (point : value) (key : string) : string =
  match to_map (getp point "alias") with
  | Map _ as alias -> (match getp alias key with Str s -> s | _ -> "")
  | _ -> ""

(* The value the call or its entity gives a point's parameter, under its name
   or the point's alias for it. *)
let param_value (ctx : ctx) (point : value) (key : string) : value =
  let akey = param_alias point key in
  let v = ref (getp ctx.c_reqmatch key) in
  if is_noval !v then v := getp ctx.c_match key;
  if is_noval !v && akey <> "" then v := getp ctx.c_reqmatch akey;
  if is_noval !v then v := getp ctx.c_reqdata key;
  if is_noval !v then v := getp ctx.c_data key;
  if is_noval !v && akey <> "" then begin
    v := getp ctx.c_reqdata akey;
    if is_noval !v then v := getp ctx.c_data akey
  end;
  !v

let param_util (ctx : ctx) (paramdef : value) : value =
  let pt = typify paramdef in
  let key =
    if (t_string land pt) > 0 then (match paramdef with Str s -> s | _ -> "")
    else (match getp paramdef "name" with Str s -> s | _ -> "")
  in
  let akey = param_alias ctx.c_point key in
  if akey <> "" && is_noval (getp ctx.c_reqmatch key) && is_noval (getp ctx.c_match key) then
    (match ctx.c_spec with Some sp -> setp sp.sp_alias akey (Str key) | None -> ());
  param_value ctx ctx.c_point key

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
  (* A path parameter travels in the path. The generated config lists them as
   * args.params, which prepare_params reads; params is the older list. *)
  let arg_names =
    match getp (getp ctx.c_point "args") "params" with
    | List r -> List.map (fun pd -> getp pd "name") !r
    | _ -> []
  in
  (* A header or cookie parameter travels in the headers, which
   * prepare_headers fills, unless a query parameter shares its name: then
   * both are sent. *)
  let declared =
    match getp (getp ctx.c_point "args") "query" with
    | List r -> List.map (fun qd -> getp qd "name") !r
    | _ -> []
  in
  let header_names =
    match getp (getp ctx.c_point "args") "header" with
    | List r -> List.map (fun hd -> getp hd "name") !r
    | _ -> []
  in
  let cookie_names =
    match getp (getp ctx.c_point "args") "cookie" with
    | List r -> List.map (fun cd -> getp cd "name") !r
    | _ -> []
  in
  let elsewhere = List.filter (fun n -> not (List.mem n declared)) (header_names @ cookie_names) in
  let params = params @ arg_names @ elsewhere in
  let contains_param s = List.exists (fun v -> match v with Str x -> x = s | _ -> false) params in
  (* A query parameter travels under the name the definition gives it, its
   * orig, which the model may have renamed for the caller. *)
  let wire =
    match getp (getp ctx.c_point "args") "query" with
    | List r ->
      List.filter_map (fun qd ->
          match getp qd "name", getp qd "orig" with
          | Str n, Str o when o <> "" -> Some (n, o)
          | _ -> None) !r
    | _ -> []
  in
  let wire_name k = match List.assoc_opt k wire with Some o -> o | None -> k in
  let out = empty_map () in
  List.iter (fun k ->
      let v = getp reqmatch k in
      if not (is_noval v) && k <> "$action" && not (contains_param k) then
        setp out (wire_name k) v)
    (keysof reqmatch);
  (* A create or update passes its query arguments in its data. *)
  List.iter (fun (name, orig, v) ->
      match v with
      | Noval | Null -> ()
      | v -> if not (contains_param name) then setp out orig v)
    (call_args ctx "query");
  out

let prepare_body_util (ctx : ctx) : value =
  if ctx.c_op.op_input <> "data" then Noval
  else if is_raw_request ctx.c_point then raw_body ctx.c_reqdata
  else (cu ctx).u_transform_request ctx

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

(* prepare_auth lives in its own GENERATED module, Sdk_prepare_auth
 * (src/cmp/ocaml/PrepareAuth_ocaml.ts), and this is the binding every caller
 * still reaches it by.
 *
 * WHY IT LEFT THIS FILE. WHERE the credential goes - a header, a query
 * parameter or a cookie, and under what name - is a fact about the API, which
 * apidef resolves into main.kit.info.security. A template can hold only one
 * answer, so this one hardcoded an `authorization` header and an
 * apiKey-in-query API (joplin's `?token=`) got a header it does not read and
 * never got the parameter it does. The three placements need three different
 * bodies, so the body is generated and the name stays here.
 *
 * The alias is not cosmetic: `new_utility`/`register` below bind
 * `u_prepare_auth` to this name, make_spec_util calls it through the utility
 * record, the secrets feature re-runs it the same way, and
 * test/primary_utility_test.ml reaches `prepare_auth_util` by `open
 * Sdk_runtime` to drive the shared corpus section. All of that is unchanged. *)
let prepare_auth_util = Sdk_prepare_auth.prepare_auth_util

(* ----- transforms / result helpers ----- *)

let omit_keys (reqdata : value) (names : string list) : value =
  match reqdata with
  | Map _ when List.exists (fun n -> List.mem n (keysof reqdata)) names ->
    let body = empty_map () in
    List.iter (fun k -> if not (List.mem k names) then setp body k (getp reqdata k))
      (keysof reqdata);
    body
  | _ -> reqdata

(* `$action` selects the point (see make_point_util); it is never an API
   field, so the body is a copy without it. The caller's map is left
   untouched. *)
let strip_action (reqdata : value) : value = omit_keys reqdata ["$action"]

let field_arg (ctx : ctx) (name : string) : bool =
  List.exists (fun kind ->
      match getp (getp ctx.c_point "args") kind with
      | List r ->
        List.exists (fun ad ->
            match getp ad "name", getp ad "field" with
            | Str n, Bool true -> n = name
            | _ -> false) !r
      | _ -> false)
    ["header"; "cookie"; "query"]

(* A header, cookie or query argument travels where prepare_headers_util or
   prepare_query_util sends it, so the body is built from the request data
   without it, unless the point marks it as a field the body keeps. *)
let routed_arg_names (ctx : ctx) : string list =
  List.filter (fun name -> not (field_arg ctx name))
    (List.map (fun (name, _, _) -> name)
       (call_args ctx "header" @ call_args ctx "cookie" @ call_args ctx "query"))

let transform_request_util (ctx : ctx) : value =
  (match ctx.c_spec with Some s -> s.sp_step <- "reqform" | None -> ());
  let data = omit_keys ctx.c_reqdata (routed_arg_names ctx) in
  strip_action
    (match to_map (getp ctx.c_point "transform") with
     | Map _ as tr ->
       (match getp tr "req" with
        | Noval -> data
        | reqform -> transform (jo [("reqdata", data)]) reqform)
     | _ -> data)

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

let preview_length = 160

(* Whitespace runs as one space, trimmed. *)
let flatten_space (s : string) : string =
  let b = Buffer.create (String.length s) in
  let space = ref false in
  String.iter (fun c ->
      match c with
      | ' ' | '\t' | '\n' | '\r' | '\011' | '\012' -> space := Buffer.length b > 0
      | _ ->
        if !space then (Buffer.add_char b ' '; space := false);
        Buffer.add_char b c) s;
  Buffer.contents b

(* Cleaned whole: a secret the bound would split could leave its prefix. *)
let body_preview (ctx : ctx) (text : value) : string =
  let flat = vstring (clean_util ctx (Str (flatten_space (vstring text)))) in
  let n = String.length flat in
  let rec cut i points =
    if i >= n then flat
    else if Char.code flat.[i] land 0xC0 = 0x80 then cut (i + 1) points
    else if points = preview_length then String.sub flat 0 i ^ "..."
    else cut (i + 1) (points + 1) in
  cut 0 0

(* A body that is not JSON. An HTTP failure keeps its own error, with the
 * response described; otherwise the code tells a wrong content type from
 * malformed JSON. *)
let unreadable_body (ctx : ctx) (status : int) (headers : value) (text : value) (sent : value)
    (failed : sdk_error option) : sdk_error =
  let ctype = vstring (header_ci headers "content-type") in
  let agent = vstring (clean_util ctx (Str (vstring (header_ci sent "user-agent")))) in
  let detail = "HTTP " ^ string_of_int status ^ ", content-type " ^
               (if ctype = "" then "none" else ctype) ^ ", user-agent " ^
               (if agent = "" then "transport default" else agent) ^
               (match text with Noval | Null -> "" | _ -> ", body: " ^ body_preview ctx text) in
  match failed with
  | Some e -> e.err_msg <- e.err_msg ^ " (" ^ detail ^ ")"; e
  | None ->
    let lower = String.lowercase_ascii ctype in
    let rec has_json i =
      i + 4 <= String.length lower && (String.sub lower i 4 = "json" || has_json (i + 1)) in
    if ctype = "" || has_json 0 then
      ctx_make_error ctx "response_json_invalid" ("response: body is not valid JSON (" ^ detail ^ ")")
    else
      ctx_make_error ctx "response_content_type"
        ("response: expected JSON, got " ^ ctype ^ " (" ^ detail ^ ")")

let result_body_util (ctx : ctx) : unit =
  match ctx.c_response, ctx.c_result with
  | Some response, Some result ->
    if is_callable response.rs_json && not (is_noval response.rs_body) then
      result.rt_body <- call_json response.rs_json;
    if response.rs_unreadable then begin
      let sent = match ctx.c_spec with Some sp -> sp.sp_headers | None -> Noval in
      result.rt_err <- Some (unreadable_body ctx result.rt_status result.rt_headers
                               response.rs_body sent result.rt_err)
    end
  | _ -> ()

let result_headers_util (ctx : ctx) : unit =
  match ctx.c_result with
  | None -> ()
  | Some result ->
    (match ctx.c_response with
     | Some response -> (match response.rs_headers with Map _ as m -> result.rt_headers <- m | _ -> result.rt_headers <- empty_map ())
     | None -> result.rt_headers <- empty_map ())

(* ----- make_* pipeline stages ----- *)

(* The {name} placeholders in a text, in order. *)
let placeholders (s : string) : string list =
  let n = String.length s in
  let rec close j = if j < n && not (String.contains "{}/" s.[j]) then close (j + 1) else j in
  let rec scan i acc =
    if i >= n then List.rev acc
    else if s.[i] <> '{' then scan (i + 1) acc
    else
      let j = close (i + 1) in
      if j < n && s.[j] = '}' && j > i + 1 then scan (j + 1) (String.sub s i (j - i + 1) :: acc)
      else scan (i + 1) acc
  in
  scan 0 []

(* The path parameters of a point that neither the call nor the entity gives
   a value for, looked up as param_util looks them up. *)
let unfilled_params (ctx : ctx) (point : value) : string list =
  match getp point "parts" with
  | List r ->
    List.filter_map (fun part ->
        match part with
        | Str s when placeholders s = [s] ->
          let name = String.sub s 1 (String.length s - 2) in
          (match param_value ctx point name with Noval | Null -> Some name | _ -> None)
        | _ -> None) !r
  | _ -> []

let make_point_util (ctx : ctx) : (value * sdk_error option) =
  match Hashtbl.find_opt ctx.c_out "point" with
  | Some (OErr e) -> (Noval, Some e)
  | Some (OPoint p) -> ctx.c_point <- p; (p, None)
  | _ ->
    let op = ctx.c_op in
    let options = ctx.c_options in
    let allow_op = match getpath_s options "allow.op" with Str s -> s | _ -> "" in
    if not (allow_list_has (getpath_s options "allow.op") op.op_name) then
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
          let own_point pts =
            List.fold_left (fun best cand ->
                let ct = terminal_param cand and bt = terminal_param best in
                if ct <> bt then (if ct then cand else best)
                else if parts_len cand < parts_len best then cand else best)
              (List.hd pts) pts in
          (* A call without an action falls back to a point without one, as
             generation does, and only to a route the call can fill. *)
          let plain = List.filter (fun p ->
              is_noval (getp (to_map (getp p "select")) "$action")) points in
          if plain = [] then
            raise (Sdk_error_exc (ctx_make_error ctx "point_action_required"
              ("Operation \"" ^ op.op_name ^ "\" has only action endpoints; pass $action to choose one.")));
          match List.filter (fun p -> unfilled_params ctx p = []) plain with
          | [] ->
            raise (Sdk_error_exc (ctx_make_error ctx "point_no_match"
              ("Operation \"" ^ op.op_name ^ "\" has no endpoint whose path parameters are all given (missing: " ^
               String.concat ", " (unfilled_params ctx (own_point plain)) ^ ").")))
          | fillable -> chosen := own_point fillable
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
    if not (allow_list_has (getpath_s options "allow.method") sp.sp_method) then
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
      (* Whatever prepare_auth sets in the query, under whichever name, is the
       * credential; a key it leaves as it was is the caller's. *)
      let query = List.map (fun k -> (k, getp sp.sp_query k)) (keysof sp.sp_query) in
      let note (s : spec) =
        s.sp_authquery <- List.filter (fun k ->
            match List.assoc_opt k query with
            | Some was -> not (veq was (getp s.sp_query k))
            | None -> true) (keysof s.sp_query) in
      match u.u_prepare_auth ctx with
      | (_, Some err) -> (None, Some err)
      | (Some spec2, None) -> note spec2; ctx.c_spec <- Some spec2; (Some spec2, None)
      | (None, None) -> note sp; (Some sp, None)
    end

let make_url_util (ctx : ctx) : (string * sdk_error option) =
  match ctx.c_spec, ctx.c_result with
  | None, _ -> ("", Some (ctx_make_error ctx "url_no_spec" "Expected context spec property to be defined."))
  | _, None -> ("", Some (ctx_make_error ctx "url_no_result" "Expected context result property to be defined."))
  | Some spec, Some result ->
    let url = ref (join ~sep:(Str "/") ~url:true (ja [Str spec.sp_base; Str spec.sp_prefix; Str spec.sp_path; Str spec.sp_suffix])) in
    (* A route the definition ends with a slash keeps it: a server such as a
     * Django REST one redirects or refuses the route without it. *)
    let ends_slash s = String.length s > 0 && '/' = s.[String.length s - 1] in
    (match getp ctx.c_point "orig" with
     | Str o when ends_slash o && spec.sp_suffix = "" && not (ends_slash !url) -> url := !url ^ "/"
     | _ -> ());
    let resmatch = empty_map () in
    List.iter (fun key ->
        let v = getp spec.sp_params key in
        if not (is_noval v) then begin
          let encoded = escurl_s (vstring v) in
          url := str_replace_all !url ("{" ^ key ^ "}") encoded;
          setp resmatch key v
        end) (keysof spec.sp_params);
    (* A placeholder left in the route would send the request to the wrong
     * route. The base's own placeholders are server variables, resolved with
     * the options. *)
    let rec root s = if ends_slash s then root (String.sub s 0 (String.length s - 1)) else s in
    let base = root spec.sp_base in
    let blen = String.length base in
    let route =
      if String.length !url >= blen && String.sub !url 0 blen = base
      then String.sub !url blen (String.length !url - blen) else !url in
    match placeholders route with
    | _ :: _ as unfilled ->
      ("", Some (ctx_make_error ctx "url_param_missing"
         ("URL path has no value for " ^ String.concat ", " unfilled ^ ".")))
    | [] ->
      let qsep = ref "?" in
      List.iter (fun key ->
          let v = getp spec.sp_query key in
          if not (is_noval v) then begin
            url := !url ^ !qsep ^ escurl_s key ^ "=" ^ escurl_s (vstring v);
            qsep := "&";
            (* Sent with the request, never recorded as the entity's match. *)
            if not (List.mem key spec.sp_authquery) then setp resmatch key v
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
       (* A map or a list is JSON, and so is a scalar on a point that declares
          a JSON body. Anything else goes as given. *)
       (match spec.sp_body with
        | Noval -> ()
        | (Map _ | List _) as b -> setp fetchdef "body" (Str (jsonify b))
        | (Str _ | Num _ | Bool _) as b when is_json_request ctx.c_point ->
          setp fetchdef "body" (Str (jsonify b))
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
             (* A body reader that raises (a non-JSON body) fails the result,
              * as in ts; it must not escape the pipeline with the raw spec
              * still on the explain record. *)
             (try
                u.u_result_basic ctx; u.u_result_headers ctx; u.u_result_body ctx;
                (* GraphQL reports failures as a top-level `errors` array under
                 * HTTP 200, so result_basic's status check never sees them.
                 * Lift them here, before the response transform tries to
                 * unwrap data that is not there. *)
                ignore (u.u_graphql_errors ctx);
                ignore (u.u_transform_response ctx);
                if result.rt_err = None then result.rt_ok <- true
              with e ->
                result.rt_err <- Some (ctx_make_error ctx "response_body" (Printexc.to_string e)));
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


let plain_settings (settings : value) (name : string) : value =
  match settings with
  | Map _ ->
    let out = empty_map () in
    List.iter (fun k ->
        if k <> "entity" && not (name = "rbac" && k = "rules") then
          setp out k (getp settings k)) (keysof settings);
    out
  | v -> v

(* The options to scan for secrets. The feature map is keyed by feature
 * names, not field names, so it is scanned as a list: `secrets` must not
 * make every setting of that feature a secret. Entity blocks hold entity
 * settings and seeded records, never a credential, so none is scanned, and
 * nor are rbac's rules, keyed by entity and operation names. *)
let secret_scan (opts : value) (names : string list) : value =
  let out = empty_map () in
  List.iter (fun k ->
      if k <> "entity" && not (List.mem k names) then
        match k, getp opts k with
        | "feature", (Map _ as fm) ->
          setp out k (ja (List.map (fun f -> plain_settings (getp fm f) f) (keysof fm)))
        | "test", v -> setp out k (plain_settings v "")
        | _, v -> setp out k v) (keysof opts);
  out

let make_options_util (ctx : ctx) : value =
  let options = match ctx.c_options with Noval -> empty_map () | v -> v in
  (match getp options "utility" with
   | Map _ as custom_utils ->
     (match ctx.c_utility with
      | Some u -> List.iter (fun k -> setp u.u_custom k (getp custom_utils k)) (keysof custom_utils)
      | None -> ())
   | _ -> ());
  (* `auth: null` is the documented way to suppress auth outright. validate()
     treats a STORED null as "no value" (getprop returns the alt), so the
     optspec `auth` default would fire and turn the suppression into "use the
     default auth" - transmitting a credential the caller withheld. getprop_raw
     is the only reader that tells a stored Null from an absent key. Withhold
     the key across merge/validate, then restore the null below. *)
  let auth_suppressed =
    (match getprop_raw options "auth" with Null -> true | _ -> false) in
  let opts = match clone options with Map _ as m -> m | _ -> empty_map () in
  let () = if auth_suppressed then ignore (delprop opts (Str "auth")) in
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
  (* THE OPTION SPEC IS GENERATED, NOT WRITTEN HERE.

     Built from the model: main.kit.optspec for the standard options, plus one
     entry per feature this target carries, from that feature's own
     config.options / config.optspec. This file used to carry its own
     opt_spec_value - one of twenty hand-maintained copies of a schema nothing
     cross-checked - so add an option to the model instead and every ported
     target validates it.

     Parsed once and memoised by Sdk_schema: validate reads the spec and
     writes into the options, never into the spec. *)
  let optspec = Sdk_schema.opt_spec_value () in
  (* The secret registry exists BEFORE validation, fed from the raw input, so
     the constructor's own rejection of a mistyped credential is clean too. A
     shallow merge over the schema defaults: the clean block is flat. *)
  let cleanraw = empty_map () in
  List.iter (fun src -> match src with
      | Map _ -> List.iter (fun k -> setp cleanraw k (getp src k)) (keysof src)
      | _ -> ()) [getp optspec "clean"; getp cfgopts "clean"; getp opts "clean"];
  let cleancfg = make_clean_config cleanraw in
  let cleanctx = { ctx with c_options = jo [("__derived__", jo [("clean", cleancfg)])] } in
  clean_add_sensitive cleanctx (secret_scan opts ["clean"]);
  List.iter (fun src -> List.iter (clean_add_util cleanctx) (splitvalues (getpath_s src "clean.values")))
    [cfgopts; opts];
  let sys_fetch = getpath_s opts "system.fetch" in
  (* Clone the config side: merge writes into the nested maps it takes. *)
  let merged = merge (ja [empty_map (); clone cfgopts; opts]) in
  let validated =
    try validate merged optspec
    with Struct_error msg ->
      raise (Struct_error (match clean_util cleanctx (Str msg) with Str s -> s | _ -> msg)) in
  let opts = match validated with Map _ as m -> m | _ -> empty_map () in
  (* Restore the suppression the optspec default would otherwise erase. *)
  let () = if auth_suppressed then setp opts "auth" Null in
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
  let derived = jo [("clean", cleancfg);
                    ("featureorder", ja (List.map (fun s -> Str s) feature_order))] in
  setp opts "__derived__" derived;
  (* Again over the merged result: the config's own defaults can carry one. *)
  clean_add_sensitive { ctx with c_options = opts } (secret_scan opts ["clean"; "__derived__"]);
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
    u_clean_add = clean_add_util;
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
  u.u_clean_add <- clean_add_util;
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
