(* ProjectName SDK features + API-agnostic client helpers.
 *
 * The 18 pipeline features (base/test/log + the 15 enterprise features) and
 * the transport they wrap, plus make_client_base / direct / prepare / test.
 * Each feature is built by a constructor that closes over `ref`s for its
 * mutable state and returns a `feature` record whose init/hook closures
 * observe and mutate the shared pipeline state. Transport-wrapping features
 * re-bind the mutable `u_fetcher` field so later inits sit outermost. *)

open Voxgig_struct
open Sdk_types
open Sdk_helpers
open Sdk_runtime

(* ------------------------------------------------------------------ *)
(* option readers                                                      *)
(* ------------------------------------------------------------------ *)

let opt_num opts key ~default = match getp opts key with Num n -> n | _ -> default
let opt_int opts key ~default = match getp opts key with Num n -> int_of_float n | _ -> default
let opt_str opts key ~default = match getp opts key with Str s -> s | _ -> default
let opt_active opts = getp opts "active" = Bool true

let opt_str_list opts key ~default =
  match getp opts key with
  | List r -> List.filter_map (function Str s -> Some s | _ -> None) !r
  | _ -> default

let now_of opts =
  match getp opts "now" with
  | Func _ as f -> (match call_vfn f Noval with Num n -> n | _ -> 0.0)
  | _ -> default_now_ms ()

let sleep_of opts (ms : float) =
  if ms > 0.0 then
    (match getp opts "sleep" with Func _ as f -> ignore (call_vfn f (Num ms)) | _ -> ())

let track_bucket (client : sdk_client) (name : string) (mk : unit -> value) : value =
  match track_get client name with
  | Map _ as m -> m
  | _ -> let m = mk () in track_set client name m; m

let bump_num (m : value) (key : string) (by : float) =
  setp m key (Num ((match getp m key with Num n -> n | _ -> 0.) +. by))

let string_upper = String.uppercase_ascii
let string_lower = String.lowercase_ascii

let header_ci (headers : value) (name : string) : value =
  let lname = string_lower name in
  let rec go = function
    | [] -> Noval
    | k :: rest -> if string_lower k = lname then getp headers k else go rest
  in
  go (keysof headers)

let ends_with s suf =
  let ls = String.length s and lf = String.length suf in
  ls >= lf && String.sub s (ls - lf) lf = suf

let strip_lead_dot s =
  if String.length s > 0 && s.[0] = '.' then String.sub s 1 (String.length s - 1) else s

let url_host (url : string) : string =
  let n = String.length url in
  let rec find i = if i + 3 > n then None else if String.sub url i 3 = "://" then Some (i + 3) else find (i + 1) in
  match find 0 with
  | Some start ->
    let rec endp j = if j >= n then j else (match url.[j] with '/' | ':' -> j | _ -> endp (j + 1)) in
    let e = endp start in String.sub url start (e - start)
  | None -> url

let vstr_of (v : value) : string = match v with Str s -> s | Noval | Null -> "" | _ -> js_string v

let rec take_n n l =
  if n <= 0 then ([], l)
  else match l with [] -> ([], []) | x :: xs -> let (a, b) = take_n (n - 1) xs in (x :: a, b)

(* ------------------------------------------------------------------ *)
(* base / log                                                          *)
(* ------------------------------------------------------------------ *)

let base_feature () : feature =
  { f_name = "base"; f_version = "0.0.1"; f_active = true; f_options = Noval;
    f_init = (fun _ _ -> ()); f_hook = (fun _ _ -> ()) }

let log_feature () : feature =
  let f = { f_name = "log"; f_version = "0.0.1"; f_active = true; f_options = Noval;
            f_init = (fun _ _ -> ()); f_hook = (fun _ _ -> ()) } in
  f.f_init <- (fun _ctx opts -> f.f_active <- opt_active opts);
  f

(* ------------------------------------------------------------------ *)
(* retry                                                               *)
(* ------------------------------------------------------------------ *)

let retry_feature () : feature =
  let options = ref (empty_map ()) in
  let f = { f_name = "retry"; f_version = "0.0.1"; f_active = true; f_options = Noval;
            f_init = (fun _ _ -> ()); f_hook = (fun _ _ -> ()) } in
  let retry_after res_v =
    match res_v with
    | Map _ ->
      (match getp res_v "headers" with
       | Map _ as h -> (match header_ci h "retry-after" with
           | Noval | Null -> None
           | v -> (try Some (float_of_string (vstr_of v) *. 1000.) with _ -> None))
       | _ -> None)
    | _ -> None
  in
  let statuses () = match getp !options "statuses" with
    | List r -> List.filter_map (function Num n -> Some (int_of_float n) | _ -> None) !r
    | _ -> [408; 425; 429; 500; 502; 503; 504] in
  let retryable res_v err raised =
    if raised <> None || err <> None then true
    else if is_noval res_v then true
    else (match getp res_v "status" with
        | Num n -> List.mem (int_of_float n) (statuses ())
        | _ -> false) in
  let backoff res_v attempt =
    let min_delay = opt_num !options "minDelay" ~default:50. in
    let max_delay = opt_num !options "maxDelay" ~default:2000. in
    let factor = opt_num !options "factor" ~default:2. in
    match retry_after res_v with
    | Some ra -> Float.min max_delay ra
    | None ->
      let base = min_delay *. (factor ** float_of_int attempt) in
      let jitter = if getp !options "jitter" = Bool false then 0. else Random.float 1. *. min_delay in
      Float.min max_delay (base +. jitter) in
  let track ctx =
    let cl = cc ctx in
    let bucket = track_bucket cl "retry" (fun () -> jo [("attempts", Num 0.); ("retries", empty_list ())]) in
    bump_num bucket "attempts" 1. in
  let with_retry ctx url fetchdef inner =
    let retries = opt_int !options "retries" ~default:2 in
    let attempt = ref 0 in
    let result = ref (Noval, None) in
    let running = ref true in
    while !running do
      let res = ref Noval and err = ref None and raised = ref None in
      (try let (r, e) = inner ctx url fetchdef in res := r; err := e
       with e -> raised := Some e);
      if not (retryable !res !err !raised) || !attempt >= retries then begin
        (match !raised with Some e -> raise e | None -> ());
        result := (!res, !err); running := false
      end else begin
        let wait = backoff !res !attempt in
        track ctx;
        sleep_of !options wait;
        incr attempt
      end
    done;
    !result in
  f.f_init <- (fun ctx opts ->
      options := (match to_map opts with Map _ -> opts | _ -> empty_map ());
      f.f_active <- opt_active opts;
      if f.f_active then begin
        let u = cu ctx in
        let inner = u.u_fetcher in
        u.u_fetcher <- (fun fctx url fd -> with_retry fctx url fd inner)
      end);
  f

(* ------------------------------------------------------------------ *)
(* timeout                                                             *)
(* ------------------------------------------------------------------ *)

let timeout_feature () : feature =
  let options = ref (empty_map ()) in
  let f = { f_name = "timeout"; f_version = "0.0.1"; f_active = true; f_options = Noval;
            f_init = (fun _ _ -> ()); f_hook = (fun _ _ -> ()) } in
  let track ctx ms =
    let cl = cc ctx in
    let bucket = track_bucket cl "timeout" (fun () -> jo [("count", Num 0.); ("ms", Num ms)]) in
    bump_num bucket "count" 1. in
  let with_timeout ctx url fetchdef inner =
    let ms = opt_num !options "ms" ~default:30000. in
    if ms <= 0. then inner ctx url fetchdef
    else begin
      let fd = match clone fetchdef with Map _ as m -> m | _ -> empty_map () in
      setp fd "timeout" (Num (ms /. 1000.));
      let start = now_of !options in
      let (res, err) = inner ctx url fd in
      let elapsed = now_of !options -. start in
      if elapsed > ms then begin
        track ctx ms;
        (Noval, Some (ctx_make_error ctx "timeout" ("Request exceeded timeout of " ^ string_of_int (int_of_float ms) ^ "ms")))
      end else (res, err)
    end in
  f.f_init <- (fun ctx opts ->
      options := (match to_map opts with Map _ -> opts | _ -> empty_map ());
      f.f_active <- opt_active opts;
      if f.f_active then begin
        let u = cu ctx in
        let inner = u.u_fetcher in
        u.u_fetcher <- (fun fctx url fd -> with_timeout fctx url fd inner)
      end);
  f

(* ------------------------------------------------------------------ *)
(* ratelimit                                                           *)
(* ------------------------------------------------------------------ *)

let ratelimit_feature () : feature =
  let options = ref (empty_map ()) in
  let tokens = ref 0. and last = ref 0. in
  let f = { f_name = "ratelimit"; f_version = "0.0.1"; f_active = true; f_options = Noval;
            f_init = (fun _ _ -> ()); f_hook = (fun _ _ -> ()) } in
  let rate () = match getp !options "rate" with Num n when n <> 0. -> n | _ -> 5. in
  let burst () = match getp !options "burst" with Num n -> n | _ -> rate () in
  let track ctx wait_ms =
    let cl = cc ctx in
    let bucket = track_bucket cl "ratelimit" (fun () -> jo [("throttled", Num 0.); ("waitMs", Num 0.)]) in
    bump_num bucket "throttled" 1.; bump_num bucket "waitMs" wait_ms in
  let acquire ctx =
    let r = rate () and b = burst () in
    let now = now_of !options in
    let elapsed = now -. !last in
    last := now;
    tokens := Float.min b (!tokens +. (elapsed /. 1000.) *. r);
    if !tokens >= 1. then tokens := !tokens -. 1.
    else begin
      let needed = 1. -. !tokens in
      let wait_ms = Float.of_int (int_of_float (ceil ((needed /. r) *. 1000.))) in
      track ctx wait_ms;
      sleep_of !options wait_ms;
      last := now_of !options;
      tokens := 0.
    end in
  f.f_init <- (fun ctx opts ->
      options := (match to_map opts with Map _ -> opts | _ -> empty_map ());
      f.f_active <- opt_active opts;
      if f.f_active then begin
        tokens := burst ();
        last := now_of !options;
        let u = cu ctx in
        let inner = u.u_fetcher in
        u.u_fetcher <- (fun fctx url fd -> acquire fctx; inner fctx url fd)
      end);
  f

(* ------------------------------------------------------------------ *)
(* cache                                                               *)
(* ------------------------------------------------------------------ *)

let cache_feature () : feature =
  let options = ref (empty_map ()) in
  let store = ref [] in
  let f = { f_name = "cache"; f_version = "0.0.1"; f_active = true; f_options = Noval;
            f_init = (fun _ _ -> ()); f_hook = (fun _ _ -> ()) } in
  let track ctx kind =
    let cl = cc ctx in
    let bucket = track_bucket cl "cache" (fun () -> jo [("hit", Num 0.); ("miss", Num 0.); ("bypass", Num 0.)]) in
    bump_num bucket kind 1. in
  let cacheable res = match res with
    | Map _ -> (match getp res "status" with Num n -> n >= 200. && n < 300. | _ -> false)
    | _ -> false in
  let snapshot res =
    let data = match getp res "json" with Func _ as fn -> (try call_json fn with _ -> Noval) | _ -> Noval in
    let headers = empty_map () in
    (match getp res "headers" with Map _ as h -> List.iter (fun k -> setp headers (string_lower k) (getp h k)) (keysof h) | _ -> ());
    jo [("status", getp res "status"); ("statusText", getp res "statusText"); ("data", data); ("headers", headers)] in
  let replay snap =
    let data = getp snap "data" in
    jo [("status", getp snap "status"); ("statusText", getp snap "statusText");
        ("body", Str "not-used"); ("json", json_thunk data);
        ("headers", (match clone (getp snap "headers") with Map _ as m -> m | _ -> empty_map ()))] in
  let evict () =
    let mx = opt_int !options "max" ~default:256 in
    while List.length !store >= mx do (match !store with _ :: tl -> store := tl | [] -> ()) done in
  let through ctx url fetchdef inner =
    let meth = match getp fetchdef "method" with Str s -> string_upper s | _ -> "GET" in
    let methods = List.map string_upper (opt_str_list !options "methods" ~default:["GET"]) in
    if not (List.mem meth methods) then inner ctx url fetchdef
    else begin
      let key = meth ^ " " ^ url in
      let now = now_of !options in
      match List.assoc_opt key !store with
      | Some hit when (match getp hit "expiry" with Num e -> e > now | _ -> false) ->
        track ctx "hit"; (replay (getp hit "snapshot"), None)
      | _ ->
        let (res, err) = inner ctx url fetchdef in
        if err = None && cacheable res then begin
          let snap = snapshot res in
          let ttl = opt_num !options "ttl" ~default:5000. in
          evict ();
          store := (List.remove_assoc key !store) @ [(key, jo [("expiry", Num (now +. ttl)); ("snapshot", snap)])];
          track ctx "miss";
          (replay snap, None)
        end else (track ctx "bypass"; (res, err))
    end in
  f.f_init <- (fun ctx opts ->
      options := (match to_map opts with Map _ -> opts | _ -> empty_map ());
      f.f_active <- opt_active opts;
      if f.f_active then begin
        store := [];
        let u = cu ctx in
        let inner = u.u_fetcher in
        u.u_fetcher <- (fun fctx url fd -> through fctx url fd inner)
      end);
  f

(* ------------------------------------------------------------------ *)
(* idempotency                                                         *)
(* ------------------------------------------------------------------ *)

let idempotency_feature () : feature =
  let options = ref (empty_map ()) in
  let f = { f_name = "idempotency"; f_version = "0.0.1"; f_active = true; f_options = Noval;
            f_init = (fun _ _ -> ()); f_hook = (fun _ _ -> ()) } in
  let genkey () = match getp !options "keygen" with Func _ as fn -> vstr_of (call_vfn fn Noval) | _ -> random_id16 () in
  let mutating ctx =
    let methods = List.map string_upper (opt_str_list !options "methods" ~default:["POST"; "PUT"; "PATCH"; "DELETE"]) in
    let meth = match ctx.c_spec with Some s -> string_upper s.sp_method | None -> "" in
    if meth <> "" && List.mem meth methods then true
    else List.mem ctx.c_op.op_name (opt_str_list !options "ops" ~default:["create"; "update"; "remove"]) in
  f.f_init <- (fun _ctx opts ->
      options := (match to_map opts with Map _ -> opts | _ -> empty_map ());
      f.f_active <- opt_active opts);
  f.f_hook <- (fun name ctx ->
      if name = "PreRequest" && f.f_active then
        match ctx.c_spec with
        | None -> ()
        | Some spec ->
          if mutating ctx then begin
            let header = opt_str !options "header" ~default:"Idempotency-Key" in
            if is_noval (header_ci spec.sp_headers header) then begin
              let key = genkey () in
              setp spec.sp_headers header (Str key);
              let cl = cc ctx in
              let bucket = track_bucket cl "idempotency" (fun () -> jo [("issued", Num 0.); ("last", Noval)]) in
              bump_num bucket "issued" 1.;
              setp bucket "last" (Str key)
            end
          end);
  f

(* ------------------------------------------------------------------ *)
(* rbac (PrePoint short-circuit)                                       *)
(* ------------------------------------------------------------------ *)

let rbac_feature () : feature =
  let options = ref (empty_map ()) in
  let perms = ref [] in
  let f = { f_name = "rbac"; f_version = "0.0.1"; f_active = true; f_options = Noval;
            f_init = (fun _ _ -> ()); f_hook = (fun _ _ -> ()) } in
  let track ctx required allowed =
    let cl = cc ctx in
    let bucket = track_bucket cl "rbac" (fun () -> jo [("allowed", Num 0.); ("denied", Num 0.); ("last", Noval)]) in
    bump_num bucket (if allowed then "allowed" else "denied") 1.;
    setp bucket "last" (jo [("required", Str required); ("allowed", Bool allowed);
                            ("op", Str ctx.c_op.op_name)]) in
  let required ctx =
    let rules = match getp !options "rules" with Map _ as m -> m | _ -> empty_map () in
    let entity = match ctx.c_entity with Some e -> e.e_name | None -> (if ctx.c_op.op_entity <> "" then ctx.c_op.op_entity else "") in
    let opname = ctx.c_op.op_name in
    let rule_for k = match getp rules k with Noval | Null -> None | v -> Some (vstr_of v) in
    (match rule_for (entity ^ "." ^ opname) with Some v -> Some v
     | None -> (match rule_for opname with Some v -> Some v
       | None -> (match rule_for "*" with Some v -> Some v | None -> None))) in
  let reject ctx req =
    track ctx req false;
    let opname = if ctx.c_op.op_name <> "" && ctx.c_op.op_name <> "_" then ctx.c_op.op_name else "?" in
    let err = ctx_make_error ctx "rbac_denied"
        ("Permission \"" ^ req ^ "\" required for operation \"" ^ opname ^ "\"") in
    Hashtbl.replace ctx.c_out "point" (OErr err) in
  f.f_init <- (fun _ctx opts ->
      options := (match to_map opts with Map _ -> opts | _ -> empty_map ());
      f.f_active <- opt_active opts;
      perms := opt_str_list !options "permissions" ~default:[]);
  f.f_hook <- (fun name ctx ->
      if name = "PrePoint" && f.f_active then
        match required ctx with
        | None -> if getp !options "deny" = Bool true then reject ctx "<default-deny>"
        | Some req ->
          if List.mem "*" !perms || List.mem req !perms then track ctx req true
          else reject ctx req);
  f

(* ------------------------------------------------------------------ *)
(* metrics                                                             *)
(* ------------------------------------------------------------------ *)

let metrics_feature () : feature =
  let options = ref (empty_map ()) in
  let f = { f_name = "metrics"; f_version = "0.0.1"; f_active = true; f_options = Noval;
            f_init = (fun _ _ -> ()); f_hook = (fun _ _ -> ()) } in
  let metrics ctx = track_bucket (cc ctx) "metrics"
      (fun () -> jo [("total", jo [("count", Num 0.); ("ok", Num 0.); ("err", Num 0.); ("totalMs", Num 0.); ("maxMs", Num 0.)]);
                     ("ops", empty_map ())]) in
  let bump b ok dur =
    bump_num b "count" 1.;
    bump_num b (if ok then "ok" else "err") 1.;
    bump_num b "totalMs" dur;
    if dur > (match getp b "maxMs" with Num n -> n | _ -> 0.) then setp b "maxMs" (Num dur) in
  let record ctx ok =
    match scratch_get ctx "metrics_start" with
    | Some (Num start) ->
      scratch_del ctx "metrics_start";
      let dur = Float.max 0. (now_of !options -. start) in
      let m = metrics ctx in
      let key = ctx.c_op.op_entity ^ "." ^ ctx.c_op.op_name in
      let ops = getp m "ops" in
      let opb = match getp ops key with Map _ as b -> b
        | _ -> let b = jo [("count", Num 0.); ("ok", Num 0.); ("err", Num 0.); ("totalMs", Num 0.); ("maxMs", Num 0.)] in setp ops key b; b in
      bump (getp m "total") ok dur; bump opb ok dur
    | _ -> () in
  f.f_init <- (fun ctx opts ->
      options := (match to_map opts with Map _ -> opts | _ -> empty_map ());
      f.f_active <- opt_active opts;
      ignore (metrics ctx));
  f.f_hook <- (fun name ctx ->
      if f.f_active then match name with
        | "PrePoint" -> scratch_set ctx "metrics_start" (Num (now_of !options))
        | "PreDone" ->
          let ok = (match ctx.c_result with Some r -> r.rt_ok && r.rt_err = None | None -> false) in
          record ctx ok
        | "PreUnexpected" -> record ctx false
        | _ -> ());
  f

(* ------------------------------------------------------------------ *)
(* telemetry                                                           *)
(* ------------------------------------------------------------------ *)

let telemetry_feature () : feature =
  let options = ref (empty_map ()) in
  let seq = ref 0 in
  let f = { f_name = "telemetry"; f_version = "0.0.1"; f_active = true; f_options = Noval;
            f_init = (fun _ _ -> ()); f_hook = (fun _ _ -> ()) } in
  let telemetry ctx = track_bucket (cc ctx) "telemetry"
      (fun () -> jo [("spans", empty_list ()); ("active", Num 0.)]) in
  let gen_id kind =
    match getp !options "idgen" with
    | Func _ as fn -> vstr_of (call_vfn fn (Str kind))
    | _ ->
      incr seq;
      let n = Printf.sprintf "%04x" !seq in
      let padded = n ^ String.make (max 0 (16 - String.length n)) '0' in
      (if kind = "trace" then "t" else "s") ^ padded in
  let close ctx ok =
    match scratch_get ctx "telemetry_span" with
    | Some (Map _ as span) ->
      scratch_del ctx "telemetry_span";
      let end_ = now_of !options in
      setp span "end" (Num end_);
      setp span "durationMs" (Num (Float.max 0. (end_ -. (match getp span "start" with Num n -> n | _ -> 0.))));
      setp span "ok" (Bool ok);
      let t = telemetry ctx in
      bump_num t "active" (-1.);
      (match getp t "spans" with List r -> r := !r @ [span] | _ -> ());
      (match getp !options "exporter" with Func _ as fn -> (try ignore (call_vfn fn span) with _ -> ()) | _ -> ())
    | _ -> () in
  f.f_init <- (fun ctx opts ->
      options := (match to_map opts with Map _ -> opts | _ -> empty_map ());
      f.f_active <- opt_active opts;
      seq := 0;
      ignore (telemetry ctx));
  f.f_hook <- (fun name ctx ->
      if f.f_active then match name with
        | "PrePoint" ->
          let entity = if ctx.c_op.op_entity <> "" then ctx.c_op.op_entity else "_" in
          let opname = if ctx.c_op.op_name <> "" then ctx.c_op.op_name else "_" in
          let span = jo [("traceId", Str (gen_id "trace")); ("spanId", Str (gen_id "span"));
                         ("name", Str (entity ^ "." ^ opname)); ("start", Num (now_of !options));
                         ("end", Noval); ("durationMs", Noval); ("ok", Noval)] in
          scratch_set ctx "telemetry_span" span;
          bump_num (telemetry ctx) "active" 1.
        | "PreRequest" ->
          (match scratch_get ctx "telemetry_span", ctx.c_spec with
           | Some (Map _ as span), Some spec ->
             let hopt = match getp !options "headers" with Map _ as h -> h | _ -> empty_map () in
             let hget k d = match getp hopt k with Str s -> s | _ -> d in
             setp spec.sp_headers (hget "trace" "X-Trace-Id") (getp span "traceId");
             setp spec.sp_headers (hget "span" "X-Span-Id") (getp span "spanId");
             setp spec.sp_headers (hget "parent" "traceparent")
               (Str ("00-" ^ vstr_of (getp span "traceId") ^ "-" ^ vstr_of (getp span "spanId") ^ "-01"))
           | _ -> ())
        | "PreDone" ->
          let ok = (match ctx.c_result with Some r -> r.rt_ok && r.rt_err = None | None -> false) in
          close ctx ok
        | "PreUnexpected" -> close ctx false
        | _ -> ());
  f

(* ------------------------------------------------------------------ *)
(* debug                                                               *)
(* ------------------------------------------------------------------ *)

let debug_feature () : feature =
  let options = ref (empty_map ()) in
  let f = { f_name = "debug"; f_version = "0.0.1"; f_active = true; f_options = Noval;
            f_init = (fun _ _ -> ()); f_hook = (fun _ _ -> ()) } in
  let debug ctx = track_bucket (cc ctx) "debug" (fun () -> jo [("entries", empty_list ())]) in
  let redact headers =
    match headers with
    | Map _ ->
      let patterns = opt_str_list !options "redact"
          ~default:["authorization"; "cookie"; "set-cookie"; "api-key"; "apikey"; "x-api-key"; "idempotency-key"] in
      let out = empty_map () in
      List.iter (fun k -> if List.mem (string_lower k) patterns then setp out k (Str "<redacted>") else setp out k (getp headers k)) (keysof headers);
      out
    | _ -> empty_map () in
  let finish ctx ok =
    match scratch_get ctx "debug_entry" with
    | Some (Map _ as entry) ->
      scratch_del ctx "debug_entry";
      let result_ok = match ctx.c_result with Some r -> r.rt_ok | None -> true in
      setp entry "ok" (Bool (ok && result_ok));
      setp entry "durationMs" (Num (Float.max 0. (now_of !options -. (match getp entry "start" with Num n -> n | _ -> 0.))));
      (if getp entry "status" = Noval then match ctx.c_result with Some r -> setp entry "status" (vint_of r.rt_status) | None -> ());
      let buf = getp (debug ctx) "entries" in
      (match buf with List r -> r := !r @ [entry] | _ -> ());
      let mx = opt_int !options "max" ~default:100 in
      (match buf with List r -> while List.length !r > mx do (match !r with _ :: tl -> r := tl | [] -> ()) done | _ -> ());
      (match getp !options "onEntry" with Func _ as fn -> (try ignore (call_vfn fn entry) with _ -> ()) | _ -> ())
    | _ -> () in
  f.f_init <- (fun ctx opts ->
      options := (match to_map opts with Map _ -> opts | _ -> empty_map ());
      f.f_active <- opt_active opts;
      ignore (debug ctx));
  f.f_hook <- (fun name ctx ->
      if f.f_active then match name with
        | "PreRequest" ->
          let opname = (if ctx.c_op.op_entity <> "" then ctx.c_op.op_entity else "_") ^ "." ^ (if ctx.c_op.op_name <> "" then ctx.c_op.op_name else "_") in
          let entry = jo [
            ("op", Str opname);
            ("method", (match ctx.c_spec with Some s -> Str s.sp_method | None -> Noval));
            ("url", (match ctx.c_spec with Some s -> Str (if s.sp_url <> "" then s.sp_url else s.sp_path) | None -> Noval));
            ("headers", redact (match ctx.c_spec with Some s -> s.sp_headers | None -> Noval));
            ("start", Num (now_of !options)); ("status", Noval); ("ok", Noval);
            ("durationMs", Noval); ("error", Noval) ] in
          scratch_set ctx "debug_entry" entry
        | "PreResponse" ->
          (match scratch_get ctx "debug_entry" with
           | Some (Map _ as entry) ->
             (match ctx.c_response with Some r -> setp entry "status" (vint_of r.rs_status) | None -> ());
             (match getp entry "url" with (Noval | Str "") -> (match ctx.c_spec with Some s when s.sp_url <> "" -> setp entry "url" (Str s.sp_url) | _ -> ()) | _ -> ())
           | _ -> ())
        | "PreDone" -> finish ctx true
        | "PreUnexpected" ->
          (match scratch_get ctx "debug_entry" with
           | Some (Map _ as entry) ->
             (match ctx.c_ctrl.ctrl_err with Some e -> setp entry "error" (Str e.err_msg) | None -> ())
           | _ -> ());
          finish ctx false
        | _ -> ());
  f

(* ------------------------------------------------------------------ *)
(* audit                                                               *)
(* ------------------------------------------------------------------ *)

let audit_feature () : feature =
  let options = ref (empty_map ()) in
  let seq = ref 0 in
  let f = { f_name = "audit"; f_version = "0.0.1"; f_active = true; f_options = Noval;
            f_init = (fun _ _ -> ()); f_hook = (fun _ _ -> ()) } in
  let audit ctx = track_bucket (cc ctx) "audit" (fun () -> jo [("records", empty_list ())]) in
  let emit ctx outcome =
    match scratch_get ctx "audit_seen" with
    | Some (Bool true) -> ()
    | _ ->
      scratch_set ctx "audit_seen" (Bool true);
      incr seq;
      let actor = match ctx.c_ctrl.ctrl_actor with
        | Noval | Null -> (match getp !options "actor" with Noval | Null -> Str "anonymous" | a -> a)
        | a -> a in
      let record = jo [
        ("seq", vint_of !seq); ("ts", Num (now_of !options)); ("actor", actor);
        ("entity", Str (if ctx.c_op.op_entity <> "" then ctx.c_op.op_entity else "_"));
        ("op", Str (if ctx.c_op.op_name <> "" then ctx.c_op.op_name else "_"));
        ("outcome", Str outcome);
        ("status", (match ctx.c_result with Some r -> vint_of r.rt_status | None -> Noval));
        ("correlationId", Str ctx.c_id) ] in
      let records = getp (audit ctx) "records" in
      (match records with List r -> r := !r @ [record] | _ -> ());
      let mx = opt_int !options "max" ~default:1000 in
      (match records with List r -> while List.length !r > mx do (match !r with _ :: tl -> r := tl | [] -> ()) done | _ -> ());
      (match getp !options "sink" with Func _ as fn -> (try ignore (call_vfn fn record) with _ -> ()) | _ -> ()) in
  f.f_init <- (fun ctx opts ->
      options := (match to_map opts with Map _ -> opts | _ -> empty_map ());
      f.f_active <- opt_active opts;
      seq := 0;
      ignore (audit ctx));
  f.f_hook <- (fun name ctx ->
      if f.f_active then match name with
        | "PreDone" ->
          let ok = (match ctx.c_result with Some r -> r.rt_ok && r.rt_err = None | None -> false) in
          emit ctx (if ok then "ok" else "error")
        | "PreUnexpected" -> emit ctx "error"
        | _ -> ());
  f

(* ------------------------------------------------------------------ *)
(* cost                                                                *)
(* ------------------------------------------------------------------ *)
(* Prices every transport ATTEMPT and commits the spend once per
   OPERATION. Mirrors tm/ts/src/feature/cost/CostFeature.ts; the corpus
   cases are .sdk/test/feature/cost.aon.

   ORDER MATTERS. Cost must sit INSIDE the cache, or a response served from
   cache is charged for money that was never spent. Activate in array form
   with cost first: [{ name: 'cost' }, { name: 'cache' }]. *)

let cost_feature () : feature =
  let options = ref (empty_map ()) in
  (* Per-context accumulation: attempts are priced as they happen and the
     total is committed once, at PreDone. *)
  let pending : (string, value) Hashtbl.t = Hashtbl.create 8 in
  let seq = ref 0 in
  let f = { f_name = "cost"; f_version = "0.0.1"; f_active = true; f_options = Noval;
            f_init = (fun _ _ -> ()); f_hook = (fun _ _ -> ()) } in

  let per_unit () = opt_num !options "perUnit" ~default:0. in
  let limit () = opt_num !options "budget" ~default:0. in

  let record ctx =
    let cl = cc ctx in
    track_bucket cl "cost" (fun () ->
        jo [("currency", Str (opt_str !options "currency" ~default:"USD"));
            ("total", jo [("calls", Num 0.); ("attempts", Num 0.); ("amount", Num 0.);
                          ("reported", Num 0.); ("estimated", Num 0.)]);
            ("ops", empty_map ()); ("actors", empty_map ());
            ("budget", jo [("limit", Num (limit ())); ("spent", Num 0.);
                           ("remaining", Num (limit ())); ("exceeded", Bool false)]);
            ("last", Noval)]) in

  let new_pending () =
    jo [("attempts", Num 0.); ("amount", Num 0.); ("reported", Num 0.);
        ("estimated", Num 0.); ("source", Str "none"); ("piped", Bool false)] in

  let pending_for ctx =
    match Hashtbl.find_opt pending ctx.c_id with
    | Some p -> p
    | None -> let p = new_pending () in Hashtbl.replace pending ctx.c_id p; p in

  (* A header figure is server-stated, so it beats the table and the unit. *)
  let price_header res =
    let name = opt_str !options "header" ~default:"" in
    if name = "" then None
    else match header_ci (getp res "headers") name with
      | Noval | Null -> None
      | v -> (match float_of_string_opt (vstr_of v) with
          | Some n -> Some (n *. per_unit (), "header")
          | None -> None) in

  (* Same lookup grammar as rbac's rules: '<entity>.<op>', then '<op>',
     then '*'. *)
  let price_rate ctx =
    let rates = match getp !options "rates" with Map _ as m -> m | _ -> empty_map () in
    let entity = match ctx.c_entity with
      | Some e -> e.e_name
      | None -> ctx.c_op.op_entity in
    let opname = ctx.c_op.op_name in
    let pick k = match getp rates k with Num n -> Some n | _ -> None in
    match pick (entity ^ "." ^ opname) with
    | Some n -> Some (n, "table")
    | None -> (match pick opname with
        | Some n -> Some (n, "table")
        | None -> (match pick "*" with Some n -> Some (n, "table") | None -> None)) in

  let price ctx res =
    match price_header res with
    | Some p -> p
    | None ->
      match price_rate ctx with
      | Some p -> p
      | None ->
        let unit = opt_num !options "unit" ~default:0. in
        if unit <> 0. then (unit, "unit") else (0., "none") in

  (* A usage figure from the parsed result body, priced by perUnit. Read at
     commit, not at the transport seam, because the body is one-shot. *)
  let price_body ctx =
    let path = opt_str !options "path" ~default:"" in
    if path = "" then None
    else match ctx.c_result with
      | None -> None
      | Some rt ->
        (match rt.rt_body with
         | Map _ ->
           (match getpath_s rt.rt_body path with
            | Num n -> Some (n *. per_unit ())
            | Str s -> (match float_of_string_opt s with
                | Some n -> Some (n *. per_unit ()) | None -> None)
            | _ -> None)
         | _ -> None) in

  let spend rec_ amount reported estimated =
    let total = getp rec_ "total" in
    bump_num total "amount" amount;
    bump_num total "reported" reported;
    bump_num total "estimated" estimated;
    let budget = getp rec_ "budget" in
    let lim = match getp budget "limit" with Num n -> n | _ -> 0. in
    let spent = match getp total "amount" with Num n -> n | _ -> 0. in
    setp budget "spent" (Num spent);
    setp budget "remaining" (Num (if lim > 0. then max 0. (lim -. spent) else 0.));
    if lim > 0. && spent >= lim then setp budget "exceeded" (Bool true) in

  let bump bucket key amount =
    let b = match getp bucket key with
      | Map _ as m -> m
      | _ -> let m = jo [("calls", Num 0.); ("amount", Num 0.)] in setp bucket key m; m in
    bump_num b "calls" 1.;
    bump_num b "amount" amount in

  let commit ctx p entity opname =
    let rec_ = record ctx in
    let amount = ref (match getp p "amount" with Num n -> n | _ -> 0.) in
    let reported = ref (match getp p "reported" with Num n -> n | _ -> 0.) in
    let estimated = ref (match getp p "estimated" with Num n -> n | _ -> 0.) in
    let source = ref (vstr_of (getp p "source")) in

    (* A body figure prices the whole call, so it REPLACES the per-attempt
       estimate rather than adding to it - and, being server-stated, the
       whole amount counts as reported. *)
    (match price_body ctx with
     | Some b -> amount := b; reported := b; estimated := 0.; source := "body"
     | None -> ());

    spend rec_ !amount !reported !estimated;

    let actor = match ctx.c_ctrl.ctrl_actor with
      | Str a when a <> "" -> a
      | _ -> opt_str !options "actor" ~default:"anonymous" in

    bump_num (getp rec_ "total") "calls" 1.;
    bump (getp rec_ "ops") (entity ^ "." ^ opname) !amount;
    bump (getp rec_ "actors") actor !amount;

    incr seq;
    setp rec_ "last"
      (jo [("seq", Num (float_of_int !seq)); ("entity", Str entity); ("op", Str opname);
           ("actor", Str actor); ("amount", Num !amount);
           ("currency", getp rec_ "currency"); ("source", Str !source);
           ("attempts", getp p "attempts")]) in

  let finish ctx done_ =
    if f.f_active then
      match Hashtbl.find_opt pending ctx.c_id with
      | None -> ()
      | Some p ->
        Hashtbl.remove pending ctx.c_id;
        let attempts = match getp p "attempts" with Num n -> n | _ -> 0. in
        (* A FAILED operation that made no attempt never reached the network:
           the budget gate (or rbac, or an unresolvable endpoint) refused it.
           Committing would count a call that never happened.

           A SUCCEEDED operation that made no attempt is the opposite case: it
           was served from the cache. That is a real call, and the fact that it
           cost nothing is the whole point of ordering cost inside the cache. *)
        if done_ || attempts > 0. then begin
          let entity = if ctx.c_op.op_entity <> "" then ctx.c_op.op_entity else "_" in
          let opname = if ctx.c_op.op_name <> "" then ctx.c_op.op_name else "_" in
          commit ctx p entity opname
        end in

  let charge ctx url fetchdef inner =
    (* A rejecting transport still costs an attempt: without this a run of
       connection-level failures under `retry` would be charged nothing, and
       an onBudget: 'deny' ceiling could never stop it. *)
    let (res, err) = inner ctx url fetchdef in
    let (amount, source) = price ctx res in
    let p = pending_for ctx in
    bump_num p "attempts" 1.;
    bump_num p "amount" amount;
    bump_num p (if source = "header" || source = "body" then "reported" else "estimated") amount;
    setp p "source" (Str source);
    bump_num (getp (record ctx) "total") "attempts" 1.;

    (* direct() and graphql() dispatch no pipeline hooks at all - no PrePoint
       to gate on and no PreDone to commit - so their spend is committed here
       or never. `piped` is set by PrePoint, so its absence is the signal. *)
    if getp p "piped" <> Bool true then begin
      Hashtbl.remove pending ctx.c_id;
      commit ctx p "_" "direct"
    end;
    (res, err) in

  f.f_init <- (fun ctx opts ->
      options := (match to_map opts with Map _ -> opts | _ -> empty_map ());
      f.f_active <- opt_active opts;
      if f.f_active then begin
        Hashtbl.reset pending;
        seq := 0;
        ignore (record ctx);
        let u = cu ctx in
        let inner = u.u_fetcher in
        u.u_fetcher <- (fun fctx url fd -> charge fctx url fd inner)
      end);

  f.f_hook <- (fun name ctx ->
      if f.f_active then
        match name with
        | "PrePoint" ->
          (* Mark the context as piped, so charge knows a PreDone is coming. *)
          let p = pending_for ctx in
          setp p "piped" (Bool true);
          let lim = limit () in
          if lim > 0. then begin
            let rec_ = record ctx in
            let spent = match getp (getp rec_ "total") "amount" with Num n -> n | _ -> 0. in
            if spent >= lim then begin
              setp (getp rec_ "budget") "exceeded" (Bool true);
              if opt_str !options "onBudget" ~default:"warn" = "deny" then begin
                let err = ctx_make_error ctx "cost_budget"
                    ("Cost budget of " ^ js_string (Num lim) ^ " " ^ vstr_of (getp rec_ "currency")
                     ^ " is spent (" ^ js_string (Num spent) ^ " used)") in
                Hashtbl.replace ctx.c_out "point" (OErr err)
              end
            end
          end
        | "PreDone" -> finish ctx true
        | _ -> ());
  f

(* ------------------------------------------------------------------ *)
(* clienttrack                                                         *)
(* ------------------------------------------------------------------ *)

let clienttrack_feature () : feature =
  let options = ref (empty_map ()) in
  let session = ref "" and requests = ref 0 in
  let f = { f_name = "clienttrack"; f_version = "0.0.1"; f_active = true; f_options = Noval;
            f_init = (fun _ _ -> ()); f_hook = (fun _ _ -> ()) } in
  let name () = (opt_str !options "clientName" ~default:"ProjectName-SDK") ^ "/" ^ (opt_str !options "clientVersion" ~default:"0.0.1") in
  let gen_id kind =
    match getp !options "idgen" with
    | Func _ as fn -> vstr_of (call_vfn fn (Str kind))
    | _ ->
      let s = (String.sub kind 0 1) ^ "-" ^ random_id16 () in
      if String.length s > 20 then String.sub s 0 20 else s in
  let set_nc headers hname value =
    if is_noval (header_ci headers hname) then setp headers hname (Str value) in
  f.f_init <- (fun _ctx opts ->
      options := (match to_map opts with Map _ -> opts | _ -> empty_map ());
      f.f_active <- opt_active opts;
      requests := 0);
  f.f_hook <- (fun hname ctx ->
      if f.f_active then match hname with
        | "PostConstruct" ->
          session := (match getp !options "sessionId" with Str s -> s | _ -> gen_id "session");
          let cl = cc ctx in
          track_set cl "clienttrack" (jo [("session", Str !session); ("requests", Num 0.); ("clientName", Str (name ()))])
        | "PreRequest" ->
          (match ctx.c_spec with
           | None -> ()
           | Some spec ->
             if !session = "" then session := (match getp !options "sessionId" with Str s -> s | _ -> gen_id "session");
             let hopt = match getp !options "headers" with Map _ as h -> h | _ -> empty_map () in
             let hget k d = match getp hopt k with Str s -> s | _ -> d in
             incr requests;
             let request_id = gen_id "request" in
             set_nc spec.sp_headers (hget "agent" "User-Agent") (name ());
             set_nc spec.sp_headers (hget "client" "X-Client-Id") !session;
             setp spec.sp_headers (hget "request" "X-Request-Id") (Str request_id);
             let cl = cc ctx in
             let bucket = track_bucket cl "clienttrack" (fun () -> jo [("session", Str !session); ("requests", Num 0.); ("clientName", Str (name ()))]) in
             setp bucket "requests" (vint_of !requests);
             setp bucket "lastRequestId" (Str request_id))
        | _ -> ());
  f

(* ------------------------------------------------------------------ *)
(* paging                                                              *)
(* ------------------------------------------------------------------ *)

(* Relay pagination: the cursor is the `after` variable (or whatever the model
 * named it), and the page size is `first`. *)
let graphql_pre_request (options : value) (spec : spec) (point : value)
    (paging : value) : unit =
  match spec.sp_body with
  | Map _ as body ->
    let variables = match getp body "variables" with
      | Map _ as m -> m
      | _ -> let m = empty_map () in setp body "variables" m; m in

    let after_var = opt_str options "afterVar" ~default:"after" in
    let first_var = opt_str options "firstVar" ~default:"first" in

    (* Only bind variables the operation actually declares, or the server
     * rejects the document. *)
    let declared = match getpath_s point "graphql.vars" with
      | List r -> List.filter_map (fun v -> match getp v "name" with
          | Str n -> Some n | _ -> None) !r
      | _ -> [] in

    (match getp paging "cursor" with
     | Noval | Null -> ()
     | c -> if List.mem after_var declared then setp variables after_var c);

    (match getp options "limit" with
     | Noval | Null -> ()
     | lim ->
       if List.mem first_var declared && is_nullish (getp variables first_var)
       then setp variables first_var lim)
  | _ -> ()

let paging_feature () : feature =
  let options = ref (empty_map ()) in
  let f = { f_name = "paging"; f_version = "0.0.1"; f_active = true; f_options = Noval;
            f_init = (fun _ _ -> ()); f_hook = (fun _ _ -> ()) } in
  let is_list ctx = List.mem ctx.c_op.op_name (opt_str_list !options "ops" ~default:["list"]) in
  let num_of v = match v with
    | Noval | Null -> Noval
    | _ -> (try Num (float_of_string (String.trim (vstr_of v))) with _ -> Noval) in
  let extract_next link =
    match String.index_opt link '<', String.index_opt link '>' with
    | Some i, Some j when j > i ->
      let inner = String.sub link (i + 1) (j - i - 1) in
      let rest = string_lower (String.sub link (j + 1) (String.length link - j - 1)) in
      let contains hay needle =
        let hl = String.length hay and nl = String.length needle in
        let rec go k = if k + nl > hl then false else if String.sub hay k nl = needle then true else go (k + 1) in
        nl = 0 || go 0 in
      if contains rest "rel" && contains rest "next" then Some inner else None
    | _ -> None in
  f.f_init <- (fun _ctx opts ->
      options := (match to_map opts with Map _ -> opts | _ -> empty_map ());
      f.f_active <- opt_active opts);
  f.f_hook <- (fun name ctx ->
      if f.f_active && is_list ctx then match name with
        | "PreRequest" ->
          (match ctx.c_spec with
           | None -> ()
           | Some spec ->
             let q = match spec.sp_query with Map _ as m -> m | _ -> (let m = empty_map () in spec.sp_query <- m; m) in
             let page_param = opt_str !options "pageParam" ~default:"page" in
             let limit_param = opt_str !options "limitParam" ~default:"limit" in
             let cursor_param = opt_str !options "cursorParam" ~default:"cursor" in
             let paging = match ctx.c_ctrl.ctrl_paging with Map _ as m -> m | _ -> empty_map () in
             (* GraphQL paginates through operation VARIABLES, not the query
              * string. This hook runs after make_spec, so spec.sp_body already
              * holds the { query, variables } envelope, and before
              * make_fetch_def serialises it. *)
             if get_str_d ctx.c_point "kind" "" = "graphql" then
               graphql_pre_request !options spec ctx.c_point paging
             else begin
               (match getp paging "cursor" with
                | Noval | Null ->
                  (match getp q page_param with
                   | Noval ->
                     let page = (match getp paging "page" with
                         | Noval | Null -> (match getp !options "startPage" with Num n -> Num n | _ -> Num 1.)
                         | p -> p) in
                     setp q page_param page
                   | _ -> ())
                | c -> setp q cursor_param c);
               (match getp !options "limit" with
                | Noval | Null -> ()
                | lim -> (match getp q limit_param with Noval -> setp q limit_param lim | _ -> ()))
             end)
        | "PreResult" ->
          (match ctx.c_result with
           | None -> ()
           | Some result ->
             let headers = match result.rt_headers with Map _ as m -> m | _ -> empty_map () in
             let body = result.rt_body in
             let paging = jo [
               ("page", num_of (header_ci headers "x-page"));
               ("totalCount", num_of (header_ci headers "x-total-count"));
               ("nextPage", num_of (header_ci headers "x-next-page"));
               ("next", Noval); ("cursor", Noval); ("hasMore", Bool false) ] in
             (match header_ci headers "link" with
              | Noval | Null -> ()
              | l -> (match extract_next (vstr_of l) with Some n -> setp paging "next" (Str n) | None -> ()));
             (* Relay connections carry the cursor in pageInfo, at the path
              * the model recorded for this op. `explicit_more` is set when
              * the server states hasMore outright, rather than leaving it to
              * be inferred from the presence of a cursor. *)
             let explicit_more = ref false in
             let gqlpage = getpath_s ctx.c_point "graphql.page" in
             (match gqlpage, body with
              | Map _, Map _ ->
                (* `connpath` locates the connection object inside the
                 * response envelope (data.<field>); the cursor/more paths are
                 * relative to it. *)
                let connpath = get_str_d gqlpage "connpath" "" in
                let conn =
                  if connpath = "" then body
                  else (match getpath_s body connpath with
                        | Noval | Null -> body
                        | sub -> sub) in
                let cursorpath = get_str_d gqlpage "cursor" "" in
                if cursorpath <> "" then
                  (match getpath_s conn cursorpath with
                   | Noval | Null -> ()
                   | c -> setp paging "cursor" c);
                let morepath = get_str_d gqlpage "more" "" in
                if morepath <> "" then
                  (match getpath_s conn morepath with
                   | Bool b -> setp paging "hasMore" (Bool b); explicit_more := true
                   | _ -> ())
              | _ -> ());
             (match body with
              | Map _ ->
                (match getp body "next" with Noval | Null -> () | n -> if is_nullish (getp paging "next") then setp paging "next" n);
                (match getp body "cursor" with Noval | Null -> () | c -> setp paging "cursor" c);
                (match getp body "nextCursor" with Noval | Null -> () | c -> setp paging "cursor" c);
                (match getp body "hasMore" with
                 | Bool b -> setp paging "hasMore" (Bool b); explicit_more := true
                 | _ -> ())
              | _ -> ());
             (* Cursor presence only INFERS another page. When the server
              * stated the answer outright — relay's `hasNextPage: false`, or
              * a body `hasMore` — that wins: a final page normally carries
              * both an end cursor and hasNextPage false, and inferring from
              * the cursor there would send the caller back for a page that
              * does not exist, forever. *)
             if not !explicit_more then begin
               let hm = (getp paging "hasMore" = Bool true)
                        || not (is_nullish (getp paging "next"))
                        || not (is_nullish (getp paging "cursor"))
                        || not (is_nullish (getp paging "nextPage")) in
               setp paging "hasMore" (Bool hm)
             end;
             result.rt_paging <- paging;
             track_set (cc ctx) "paging" (jo [("last", paging)]))
        | _ -> ());
  f

(* ------------------------------------------------------------------ *)
(* streaming                                                           *)
(* ------------------------------------------------------------------ *)

let streaming_feature () : feature =
  let options = ref (empty_map ()) in
  let f = { f_name = "streaming"; f_version = "0.0.1"; f_active = true; f_options = Noval;
            f_init = (fun _ _ -> ()); f_hook = (fun _ _ -> ()) } in
  let streamable ctx = List.mem ctx.c_op.op_name (opt_str_list !options "ops" ~default:["list"]) in
  let iterate (result : result) : value list =
    let chunk_delay = opt_num !options "chunkDelay" ~default:0. in
    let chunk_size = opt_int !options "chunkSize" ~default:0 in
    let items = match result.rt_resdata with List r -> !r | _ -> [] in
    if chunk_size > 0 then begin
      let rec go acc l = match l with
        | [] -> List.rev acc
        | _ -> let (h, t) = take_n chunk_size l in
          (if chunk_delay > 0. then sleep_of !options chunk_delay);
          go (lst h :: acc) t in
      go [] items
    end else
      List.map (fun item -> (if chunk_delay > 0. then sleep_of !options chunk_delay); item) items in
  f.f_init <- (fun _ctx opts ->
      options := (match to_map opts with Map _ -> opts | _ -> empty_map ());
      f.f_active <- opt_active opts);
  f.f_hook <- (fun name ctx ->
      if name = "PreResult" && f.f_active && streamable ctx then
        match ctx.c_result with
        | None -> ()
        | Some result ->
          result.rt_streaming <- true;
          result.rt_stream <- Some (fun () -> iterate result);
          let bucket = track_bucket (cc ctx) "streaming" (fun () -> jo [("opened", Num 0.)]) in
          bump_num bucket "opened" 1.);
  f

(* ------------------------------------------------------------------ *)
(* proxy                                                               *)
(* ------------------------------------------------------------------ *)

let proxy_feature () : feature =
  let options = ref (empty_map ()) in
  let purl = ref Noval and noproxy = ref [] in
  let f = { f_name = "proxy"; f_version = "0.0.1"; f_active = true; f_options = Noval;
            f_init = (fun _ _ -> ()); f_hook = (fun _ _ -> ()) } in
  let env k = match Sys.getenv_opt k with Some v when v <> "" -> Some v | _ -> None in
  let bypass url =
    if !noproxy = [] then false
    else begin
      let host = url_host url in
      List.exists (fun np -> np = "*" || host = np || ends_with host ("." ^ strip_lead_dot np)) !noproxy
    end in
  let track ctx =
    let cl = cc ctx in
    let bucket = track_bucket cl "proxy" (fun () -> jo [("routed", Num 0.); ("url", !purl)]) in
    bump_num bucket "routed" 1. in
  let route ctx url fetchdef =
    if is_nullish !purl || bypass url then fetchdef
    else begin
      let out = match clone fetchdef with Map _ as m -> m | _ -> empty_map () in
      setp out "proxy" !purl;
      setp out "proxies" (jo [("http", !purl); ("https", !purl)]);
      (match getp !options "agent" with
       | Func _ as fn -> let made = call_vfn fn (ja [!purl; Str url]) in setp out "dispatcher" made; setp out "agent" made
       | _ -> ());
      track ctx;
      out
    end in
  f.f_init <- (fun ctx opts ->
      options := (match to_map opts with Map _ -> opts | _ -> empty_map ());
      f.f_active <- opt_active opts;
      if f.f_active then begin
        purl := getp !options "url";
        let np = getp !options "noProxy" in
        let np_list = ref (match np with
            | List r -> List.filter_map (function Str s -> Some s | _ -> None) !r
            | Str s -> List.filter (fun x -> x <> "") (List.map String.trim (String.split_on_char ',' s))
            | _ -> []) in
        (if getp !options "fromEnv" = Bool true then begin
           (if is_nullish !purl then
              match env "HTTPS_PROXY", env "https_proxy", env "HTTP_PROXY", env "http_proxy" with
              | Some v, _, _, _ | _, Some v, _, _ | _, _, Some v, _ | _, _, _, Some v -> purl := Str v
              | _ -> ());
           (if !np_list = [] then match env "NO_PROXY", env "no_proxy" with
              | Some v, _ | _, Some v -> np_list := List.filter (fun x -> x <> "") (List.map String.trim (String.split_on_char ',' v))
              | _ -> ())
         end);
        noproxy := !np_list;
        let u = cu ctx in
        let inner = u.u_fetcher in
        u.u_fetcher <- (fun fctx url fd -> inner fctx url (route fctx url fd))
      end);
  f

(* ------------------------------------------------------------------ *)
(* netsim (feature)                                                    *)
(* ------------------------------------------------------------------ *)

let netsim_feature () : feature =
  let options = ref (empty_map ()) in
  let calls = ref 0 and seed = ref 1 in
  let f = { f_name = "netsim"; f_version = "0.0.1"; f_active = true; f_options = Noval;
            f_init = (fun _ _ -> ()); f_hook = (fun _ _ -> ()) } in
  let rand () =
    seed := (!seed * 1103515245 + 12345) land 0x7fffffff;
    float_of_int !seed /. float_of_int 0x7fffffff in
  let pick_latency () =
    match getp !options "latency" with
    | Noval | Null -> 0.
    | Num n -> if n < 0. then 0. else n
    | Map _ as lat ->
      let mn = match getp lat "min" with Num n -> int_of_float n | _ -> 0 in
      let mx = match getp lat "max" with Num n -> int_of_float n | _ -> mn in
      if mx <= mn then float_of_int mn
      else float_of_int (mn + int_of_float (rand () *. float_of_int (mx - mn)))
    | _ -> 0. in
  let track ctx applied =
    let cl = cc ctx in
    let bucket = track_bucket cl "netsim" (fun () -> jo [("calls", Num 0.); ("applied", empty_list ())]) in
    bump_num bucket "calls" 1.;
    (match getp bucket "applied" with List r -> r := !r @ [applied] | _ -> ());
    (match ctx.c_ctrl.ctrl_explain with Map _ -> setp ctx.c_ctrl.ctrl_explain "netsim" bucket | _ -> ()) in
  let respond ctx status data extra =
    ignore ctx;
    let out = jo [("status", vint_of status); ("statusText", Str "OK"); ("json", json_thunk data); ("body", Str "not-used")] in
    (match extra with Map _ -> List.iter (fun k -> setp out k (getp extra k)) (keysof extra) | _ -> ());
    let headers = match getp out "headers" with Map _ as h -> h | _ -> empty_map () in
    let lower = empty_map () in
    List.iter (fun k -> setp lower (string_lower k) (getp headers k)) (keysof headers);
    setp out "headers" lower;
    (out, None) in
  let simulate ctx url fetchdef inner =
    let opts = !options in
    incr calls; let call = !calls in
    let applied = empty_map () in
    if getp opts "offline" = Bool true then begin
      sleep_of opts (pick_latency ()); setp applied "offline" (Bool true); track ctx applied;
      (Noval, Some (ctx_make_error ctx "netsim_offline" ("Simulated network offline (URL was: \"" ^ url ^ "\")")))
    end
    else if call <= opt_int opts "errorTimes" ~default:0 then begin
      sleep_of opts (pick_latency ()); setp applied "error" (Bool true); track ctx applied;
      (Noval, Some (ctx_make_error ctx "netsim_conn" ("Simulated connection error (call " ^ string_of_int call ^ ")")))
    end
    else if call <= opt_int opts "rateLimitTimes" ~default:0 then begin
      sleep_of opts (pick_latency ()); setp applied "rateLimited" (Bool true); track ctx applied;
      let retry_after = match getp opts "retryAfter" with Noval | Null -> 0 | Num n -> int_of_float n | _ -> 0 in
      respond ctx 429 Noval (jo [("statusText", Str "Too Many Requests"); ("headers", jo [("retry-after", Str (string_of_int retry_after))])])
    end
    else begin
      let fail_status = match getp opts "failStatus" with Num n -> int_of_float n | _ -> 503 in
      let fail_every = opt_int opts "failEvery" ~default:0 in
      let fail_rate = opt_num opts "failRate" ~default:0. in
      let fail_by_count = call <= opt_int opts "failTimes" ~default:0 in
      let fail_by_every = fail_every > 0 && call mod fail_every = 0 in
      let fail_by_rate = fail_rate > 0. && rand () < fail_rate in
      if fail_by_count || fail_by_every || fail_by_rate then begin
        sleep_of opts (pick_latency ()); setp applied "failStatus" (vint_of fail_status); track ctx applied;
        respond ctx fail_status Noval (jo [("statusText", Str "Simulated Failure")])
      end else begin
        let latency = pick_latency () in
        setp applied "latency" (Num latency); track ctx applied;
        sleep_of opts latency;
        inner ctx url fetchdef
      end
    end in
  f.f_init <- (fun ctx opts ->
      options := (match to_map opts with Map _ -> opts | _ -> empty_map ());
      f.f_active <- opt_active opts;
      seed := (match getp !options "seed" with Num n when int_of_float n <> 0 -> int_of_float n | _ -> 1);
      if f.f_active then begin
        let u = cu ctx in
        let inner = u.u_fetcher in
        u.u_fetcher <- (fun fctx url fd -> simulate fctx url fd inner)
      end);
  f

(* ------------------------------------------------------------------ *)
(* test feature (in-memory mock transport + optional net simulation)   *)
(* ------------------------------------------------------------------ *)

let test_feature () : feature =
  let f = { f_name = "test"; f_version = "0.0.1"; f_active = true; f_options = Noval;
            f_init = (fun _ _ -> ()); f_hook = (fun _ _ -> ()) } in
  (* THE MOCK HAS TO AGREE WITH THE MODEL. A point carrying
     `transform.res: `body.item`` describes an API that answers {"item": {...}}
     and the response transform unwraps that key on the way back. Returning the
     bare payload means the transform unwraps a property that is not there and
     the caller gets nothing. Mirrors the go/ts/lua/php mocks. *)
  let envelope ctx data =
    if is_nullish data then data
    else
      match getp (getp ctx.c_point "transform") "res" with
      | Str spec ->
        let n = String.length spec in
        (* Exactly `body.<key>`; a deeper path is not an envelope this mock
           can synthesise, so it is left alone rather than guessed at. *)
        if n > 7 && String.sub spec 0 6 = "`body." && spec.[n - 1] = '`' then
          let inner = String.sub spec 6 (n - 7) in
          if String.length inner = 0 || String.contains inner '.' then data
          else jo [(inner, data)]
        else data
      | _ -> data in
  let respond ctx status data extra =
    let out = jo [("status", vint_of status); ("statusText", Str "OK"); ("json", json_thunk (envelope ctx data)); ("body", Str "not-used")] in
    (match extra with Some (Map _ as e) -> List.iter (fun k -> setp out k (getp e k)) (keysof e) | _ -> ());
    (out, None) in
  let build_args ctx (op : operation) args =
    let opname = op.op_name in
    let entname = match ctx.c_entity with Some e -> e.e_name | None -> "_" in
    let points = getpath_s ctx.c_config ("entity." ^ entname ^ ".op." ^ opname ^ ".points") in
    let point = getelem points (Num (-1.0)) in
    let params_path = getpath_s point "args.params" in
    let reqd_params = select params_path (jo [("reqd", Bool true)]) in
    let reqd = transform reqd_params (ja [Str "`$EACH`"; Str ""; Str "`$KEY.name`"]) in
    let qand = ref [] in
    (match args with
     | Map _ ->
       List.iter (fun key ->
           let is_id = key = "id" in
           let selected = select reqd (Str key) in
           let is_reqd = not (isempty selected) in
           if is_id || is_reqd then begin
             let v = (cu ctx).u_param ctx (Str key) in
             let ka = (match op.op_alias with Map _ -> (match getp op.op_alias key with Str s -> Some s | _ -> None) | _ -> None) in
             let qor = ref [jo [(key, v)]] in
             (match ka with Some k -> qor := !qor @ [jo [(k, v)]] | None -> ());
             qand := !qand @ [jo [("`$OR`", ja !qor)]]
           end) (keysof args)
     | _ -> ());
    let q = jo [("`$AND`", ja !qand)] in
    (match ctx.c_ctrl.ctrl_explain with Map _ -> setp ctx.c_ctrl.ctrl_explain "test" (jo [("query", q)]) | _ -> ());
    q in
  let make_mock entity =
    let resolve_match fctx explicit =
      if (match explicit with Map _ -> size explicit > 0 | _ -> false) then explicit
      else begin
        let try_src src = match src with
          | Map _ -> (match getp src "id" with Noval -> None | Str "__UNDEFINED__" -> None | v -> Some v)
          | _ -> None in
        match try_src fctx.c_match with Some v -> jo [("id", v)]
        | None -> (match try_src fctx.c_data with Some v -> jo [("id", v)] | None -> empty_map ())
      end in
    fun fctx _url _fetchdef ->
      let op = fctx.c_op in
      let entmap = match getp entity op.op_entity with Map _ as m -> m | _ -> empty_map () in
      (match op.op_name with
       | "load" ->
         let args = build_args fctx op (resolve_match fctx fctx.c_reqmatch) in
         let ent = getelem (select entmap args) (Num 0.0) in
         if is_nullish ent then respond fctx 404 Noval (Some (jo [("statusText", Str "Not found")]))
         else (ignore (delprop ent (Str "$KEY")); respond fctx 200 (clone ent) None)
       | "list" ->
         let args = build_args fctx op fctx.c_reqmatch in
         let found = select entmap args in
         if is_nullish found then respond fctx 404 Noval (Some (jo [("statusText", Str "Not found")]))
         else begin
           (match found with List r -> List.iter (fun item -> ignore (delprop item (Str "$KEY"))) !r | _ -> ());
           respond fctx 200 (clone found) None
         end
       | "update" ->
         let update_match = empty_map () in
         (match fctx.c_reqdata with Map _ -> (match getp fctx.c_reqdata "id" with Noval -> () | v -> setp update_match "id" v) | _ -> ());
         let update_match = if size update_match > 0 then update_match else resolve_match fctx (empty_map ()) in
         let args = build_args fctx op update_match in
         let ent = ref (getelem (select entmap args) (Num 0.0)) in
         (if is_nullish !ent then match entmap with
           | Map m -> (try (match List.find (fun (_, v) -> match v with Map _ -> true | _ -> false) m.entries with (_, v) -> ent := v) with Not_found -> ())
           | _ -> ());
         if is_nullish !ent then respond fctx 404 Noval (Some (jo [("statusText", Str "Not found")]))
         else begin
           (match !ent with Map _ -> (match fctx.c_reqdata with Map _ -> List.iter (fun k -> setp !ent k (getp fctx.c_reqdata k)) (keysof fctx.c_reqdata) | _ -> ()) | _ -> ());
           ignore (delprop !ent (Str "$KEY"));
           respond fctx 200 (clone !ent) None
         end
       | "remove" ->
         let args = build_args fctx op (resolve_match fctx fctx.c_reqmatch) in
         let ent = getelem (select entmap args) (Num 0.0) in
         (match ent with Map _ -> ignore (delprop entmap (getp ent "id")) | _ -> ());
         respond fctx 200 Noval None
       | "create" ->
         ignore (build_args fctx op fctx.c_reqdata);
         let eid = let v = (cu fctx).u_param fctx (Str "id") in if is_nullish v then Str (random_id16 ()) else v in
         let ent = clone fctx.c_reqdata in
         (match ent with
          | Map _ ->
            setp ent "id" eid;
            (match eid with Str s -> setp entmap s ent | _ -> ());
            ignore (delprop ent (Str "$KEY"));
            respond fctx 200 (clone ent) None
          | _ -> respond fctx 200 ent None)
       | _ -> respond fctx 404 Noval (Some (jo [("statusText", Str "Unknown operation")]))) in
  let make_netsim net inner =
    let netcalls = ref 0 in
    let pick_latency () =
      match getp net "latency" with
      | Noval | Null -> 0.
      | Num n -> if n < 0. then 0. else n
      | Map _ as lat ->
        let mn = match getp lat "min" with Num n -> int_of_float n | _ -> 0 in
        let mx = match getp lat "max" with Num n -> int_of_float n | _ -> mn in
        if mx <= mn then float_of_int mn else float_of_int (mn + ((mx - mn) asr 1))
      | _ -> 0. in
    let sleep ms = if ms > 0. then (match getp net "sleep" with Func _ as fn -> ignore (call_vfn fn (Num ms)) | _ -> ()) in
    fun fctx url fetchdef ->
      incr netcalls; let call = !netcalls in
      if getp net "offline" = Bool true then
        (sleep (pick_latency ()); (Noval, Some (ctx_make_error fctx "netsim_offline" ("Simulated network offline (URL was: \"" ^ url ^ "\")"))))
      else if call <= (match getp net "errorTimes" with Num n -> int_of_float n | _ -> 0) then
        (sleep (pick_latency ()); (Noval, Some (ctx_make_error fctx "netsim_conn" ("Simulated connection error (call " ^ string_of_int call ^ ")"))))
      else if call <= (match getp net "failTimes" with Num n -> int_of_float n | _ -> 0) then begin
        sleep (pick_latency ());
        let status = match getp net "failStatus" with Num n -> int_of_float n | _ -> 503 in
        (jo [("status", vint_of status); ("statusText", Str "Simulated Failure"); ("body", Str "not-used"); ("json", json_thunk Noval); ("headers", empty_map ())], None)
      end
      else (sleep (pick_latency ()); inner fctx url fetchdef) in
  f.f_init <- (fun ctx opts ->
      let entity = match getp opts "entity" with Map _ as m -> m | _ -> empty_map () in
      (cc ctx).cl_mode <- "test";
      ignore (walk ~before:(fun key v _parent path ->
          (if size path = 2 && ismap v && not (is_nullish key) then ignore (setprop v (Str "id") key));
          v) entity);
      let mock = make_mock entity in
      let u = cu ctx in
      (match getp opts "net" with
       | Map _ as net -> u.u_fetcher <- make_netsim net mock
       | _ -> u.u_fetcher <- mock));
  f

(* ------------------------------------------------------------------ *)
(* client construction + direct + prepare + test                       *)
(* ------------------------------------------------------------------ *)

let make_client_base ~(config : value) ~(make_feature : string -> feature) (options : value) : sdk_client =
  let utility = new_utility () in
  register utility;
  let client = { cl_mode = "live"; cl_features = []; cl_options = Noval;
                 cl_utility = utility; cl_rootctx = None; cl_track = empty_map () } in
  let rootopts = if is_noval options then empty_map () else options in
  let rootctx = utility.u_make_context
      { (default_ctxspec ()) with cs_client = Some client; cs_utility = Some utility;
                                  cs_config = Some config; cs_options = Some rootopts;
                                  cs_shared = Some (empty_map ()) } None in
  client.cl_rootctx <- Some rootctx;
  let opts = utility.u_make_options rootctx in
  client.cl_options <- opts;
  if getpath_s opts "feature.test.active" = Bool true then client.cl_mode <- "test";
  rootctx.c_options <- opts;
  (* Add features in the resolved order (make_options records an explicit
     array order, else defaults to test-first). Ordering matters: the `test`
     feature installs the base mock transport and the transport features
     (retry/cache/netsim/proxy/ratelimit) wrap whatever is current, so `test`
     must be added before them to sit at the base of the wrapper chain. *)
  let feature_opts = match to_map (getp opts "feature") with Map _ as m -> m | _ -> empty_map () in
  let feature_order = match getpath_s opts "__derived__.featureorder" with List r -> !r | _ -> [] in
  List.iter (fun fname_v ->
      match fname_v with
      | Str fname ->
        (match to_map (getp feature_opts fname) with
         | Map _ as fopts -> if getp fopts "active" = Bool true then utility.u_feature_add rootctx (make_feature fname)
         | _ -> ())
      | _ -> ())
    feature_order;
  List.iter (fun ftr -> utility.u_feature_init rootctx ftr) client.cl_features;
  utility.u_feature_hook rootctx "PostConstruct";
  client

let prepare (client : sdk_client) (fetchargs : value) : value =
  let u = client.cl_utility in
  let fetchargs = if is_noval fetchargs then empty_map () else fetchargs in
  let ctrl = match to_map (getp fetchargs "ctrl") with Map _ as m -> m | _ -> empty_map () in
  let ctx = u.u_make_context { (default_ctxspec ()) with cs_opname = Some "prepare"; cs_ctrl = Some ctrl } client.cl_rootctx in
  let options = client.cl_options in
  let path = match getp fetchargs "path" with Str s -> s | _ -> "" in
  let method_ = match getp fetchargs "method" with Str s -> s | _ -> "GET" in
  let params = match to_map (getp fetchargs "params") with Map _ as m -> m | _ -> empty_map () in
  let query = match to_map (getp fetchargs "query") with Map _ as m -> m | _ -> empty_map () in
  let headers = u.u_prepare_headers ctx in
  let base = match getp options "base" with Str s -> s | _ -> "" in
  let prefix = match getp options "prefix" with Str s -> s | _ -> "" in
  let suffix = match getp options "suffix" with Str s -> s | _ -> "" in
  let sp = new_spec (jo [("base", Str base); ("prefix", Str prefix); ("suffix", Str suffix);
                         ("path", Str path); ("method", Str method_); ("params", params);
                         ("query", query); ("headers", headers); ("body", getp fetchargs "body");
                         ("step", Str "start")]) in
  ctx.c_spec <- Some sp;
  (match getp fetchargs "headers" with Map _ as uh -> List.iter (fun k -> setp sp.sp_headers k (getp uh k)) (keysof uh) | _ -> ());
  (match u.u_prepare_auth ctx with (_, Some err) -> raise (Sdk_error_exc err) | _ -> ());
  (match u.u_make_fetch_def ctx with (_, Some err) -> raise (Sdk_error_exc err) | (fd, None) -> fd)

(* Is this raw-access op permitted by the SDK's allow.op option? *)
let op_allowed (client : sdk_client) (op : string) : bool =
  match getpath_s client.cl_options "allow.op" with
  | Str allow -> substr_contains allow op
  | _ -> false

let op_denied (client : sdk_client) (op : string) : value =
  let allow = match getpath_s client.cl_options "allow.op" with
    | Str s -> s | _ -> "" in
  jo [("ok", Bool false);
      ("err", Str ("ProjectNameSDK: " ^ op ^ ": operation not allowed by" ^
                   " SDK option allow.op value: \"" ^ allow ^ "\""))]

(* Ungated request path shared by direct and graphql, each of which checks its
 * own allow.op token first. Separate, rather than a flag on fetchargs: a
 * caller-supplied marker would let anyone opt straight back out of the gate
 * by passing it. *)
let raw_request (client : sdk_client) (fetchargs : value) : value =
  let u = client.cl_utility in
  let fetchargs = if is_noval fetchargs then empty_map () else fetchargs in
  match (try `Ok (prepare client fetchargs) with Sdk_error_exc e -> `Err e) with
  | `Err e -> jo [("ok", Bool false); ("err", err_to_value e)]
  | `Ok fetchdef ->
    let ctrl = match to_map (getp fetchargs "ctrl") with Map _ as m -> m | _ -> empty_map () in
    let ctx = u.u_make_context { (default_ctxspec ()) with cs_opname = Some "direct"; cs_ctrl = Some ctrl } client.cl_rootctx in
    let url = match getp fetchdef "url" with Str s -> s | _ -> "" in
    let (fetched, fetch_err) = u.u_fetcher ctx url fetchdef in
    (match fetch_err with
     | Some fe -> jo [("ok", Bool false); ("err", err_to_value fe)]
     | None ->
       if is_noval fetched || fetched = Null then
         jo [("ok", Bool false); ("err", err_to_value (ctx_make_error ctx "direct_no_response" "response: undefined"))]
       else (match fetched with
         | Map _ ->
           let status = to_int (getp fetched "status") in
           let headers = match getp fetched "headers" with Map _ as m -> m | _ -> empty_map () in
           let content_length = match getp headers "content-length" with Str s -> s | Num n -> num_to_string n | _ -> "" in
           let no_body = status = 204 || status = 304 || content_length = "0" in
           let json_data = if no_body then Noval
             else (match getp fetched "json" with Func _ as jf -> (try call_json jf with _ -> Noval) | _ -> Noval) in
           jo [("ok", Bool (status >= 200 && status < 300)); ("status", vint_of status);
               ("headers", headers); ("data", json_data)]
         | _ -> jo [("ok", Bool false); ("err", err_to_value (ctx_make_error ctx "direct_invalid" "invalid response type"))]))

(* Raw endpoint access is operator-controllable, like every entity op.
 * Blocking it means denying BOTH the 'direct' and 'graphql' tokens, since
 * either one reaches the same endpoint. *)
let direct (client : sdk_client) (fetchargs : value) : value =
  if not (op_allowed client "direct") then op_denied client "direct"
  else raw_request client fetchargs

(* Raw GraphQL access: the pressure valve that makes the generated surface's
 * deliberate omissions (per-call selection sets, typed filter builders,
 * batching, subscriptions) livable — the whole schema stays reachable.
 *
 * Thin wrapper over the same prepare/fetch path direct uses, with the one
 * thing raw direct cannot do for GraphQL: a GraphQL failure rides HTTP 200 as
 * a top-level `errors` array, so status alone would report a failed query as
 * ok.
 *
 * NOTE: like direct, this bypasses the feature pipeline — no retry, ratelimit
 * or paging features apply. *)
let graphql (client : sdk_client) (query : string) (variables : value)
    (ctrl : value) : value =
  if not (op_allowed client "graphql") then op_denied client "graphql"
  else begin
    let vars = match variables with Map _ as m -> m | _ -> empty_map () in
    let ctl = match ctrl with Map _ as m -> m | _ -> empty_map () in
    let res = raw_request client (jo [
      ("method", Str "POST");
      ("headers", jo [("content-type", Str "application/json")]);
      ("body", jo [("query", Str query); ("variables", vars)]);
      ("ctrl", ctl)]) in

    (* Errors are read BEFORE any status check: a GraphQL parse or validation
     * failure comes back as HTTP 400 carrying the standard { errors: [...] }
     * body, and the raw path represents a non-2xx as ok:false with no err —
     * so returning early on status would discard the server's own
     * diagnostics, which are the only useful part of that response. *)
    let errors = match getpath_s res "data.errors" with
      | List r -> !r | _ -> [] in

    (match errors with
     | [] -> ()
     | first :: _ ->
       let msg = get_str_d first "message" "" in
       let msg = if msg = "" then "graphql error" else msg in
       setp res "ok" (Bool false);
       setp res "err" (Str ("ProjectNameSDK: graphql: " ^ msg));
       setp res "graphql" (lst errors));

    res
  end

let sdk_test ~(config : value) ~(make_feature : string -> feature) (testopts : value) (sdkopts : value) : sdk_client =
  let sdkopts = match clone (if is_noval sdkopts then empty_map () else sdkopts) with Map _ as m -> m | _ -> empty_map () in
  let testopts = match clone (if is_noval testopts then empty_map () else testopts) with Map _ as m -> m | _ -> empty_map () in
  setp testopts "active" (Bool true);
  ignore (setpath sdkopts (Str "feature.test") testopts);
  let sdk = make_client_base ~config ~make_feature sdkopts in
  sdk.cl_mode <- "test";
  sdk
