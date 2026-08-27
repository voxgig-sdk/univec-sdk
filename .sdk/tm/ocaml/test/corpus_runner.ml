(* Shared corpus harness for the Univec SDK.
 *
 * Extracted from struct_corpus.ml so the primary-utility suite can drive the
 * SAME runner over test.json's "primary" section. OCaml runs a module's
 * top-level effects on link, so a harness sitting beside a `let () = ...` main
 * cannot be reused — linking it would run the struct corpus as a side effect.
 * This module deliberately has no main.
 *)

(* Test runner for the shared JSON corpus (build/test/test.json).
 * Self-contained: an in-tree JSON reader builds the library's `value` type
 * directly, so the OCaml port is exercised exactly as in production. *)

open Voxgig_struct

let nullmark = "__NULL__"
let undefmark = "__UNDEF__"
let existsmark = "__EXISTS__"

(* The JSON reader now lives in the runtime (sdk_json.ml) so the SDK's
 * generated config can use it; the corpus runs against that same function
 * rather than a second copy that could drift from it. *)
let json_read = Sdk_json.json_read

(* ---------------- fixJSON / equality ---------------- *)

let rec fix_json v flag_null =
  match v with
  | Noval | Null -> if flag_null then Str nullmark else v
  | Map m -> let o = empty_map () in
    List.iter (fun (k, x) -> ignore (setprop o (Str k) (fix_json x flag_null))) m.entries; o
  | List r -> lst (List.map (fun x -> fix_json x flag_null) !r)
  | _ -> v

(* Order-independent deep equality for maps; sequence equality for lists. *)
let rec eqv a b =
  match a, b with
  | (Noval | Null), (Noval | Null) -> true
  | Bool x, Bool y -> x = y
  | Num x, Num y -> x = y
  | Str x, Str y -> x = y
  | List x, List y -> List.length !x = List.length !y && List.for_all2 eqv !x !y
  | Map x, Map y ->
    omap_len x = omap_len y &&
    List.for_all (fun (k, v) -> match omap_get y k with Some w -> eqv v w | None -> false) x.entries
  | _ -> a == b

(* ---------------- match support ---------------- *)

let matchval check base =
  let check = if check = Str undefmark || check = Str nullmark then Noval else check in
  if eqv check base then true
  else match check with
    | Str cs ->
      let basestr = stringify base in
      if String.length cs >= 2 && cs.[0] = '/' && cs.[String.length cs - 1] = '/' then
        Vregex.test_str (String.sub cs 1 (String.length cs - 2)) basestr
      else
        let low s = String.lowercase_ascii s in
        let contains hay needle =
          let hl = String.length hay and nl = String.length needle in
          let rec go i = if i + nl > hl then false
            else if String.sub hay i nl = needle then true else go (i + 1) in
          nl = 0 || go 0 in
        contains (low basestr) (low (stringify check))
    | Func _ -> true
    | _ -> false

let do_match check base =
  let base = clone base in
  ignore (walk ~before:(fun _k v _p path ->
      (if not (isnode v) then begin
          let baseval = getpath base path in
          if eqv baseval v then ()
          else if v = Str undefmark && is_nullish baseval then ()
          else if v = Str existsmark && not (is_nullish baseval) then ()
          else if not (matchval v baseval) then
            raise (Struct_error (Printf.sprintf "MATCH: %s: [%s] <=> [%s]"
                                   (String.concat "." (List.map js_string (match path with List r -> !r | _ -> [])))
                                   (stringify v) (stringify baseval)))
        end);
      v) check)

(* ---------------- result tracking ---------------- *)

let npass = ref 0
let nfail = ref 0
let failures = ref []

let record group name ok msg =
  if ok then incr npass
  else (incr nfail; failures := Printf.sprintf "FAIL %s %s - %s" group name msg :: !failures)

(* ---------------- per-entry runner ---------------- *)

let omap_v kvs =
  let m = empty_map () in
  List.iter (fun (k, v) -> ignore (setprop m (Str k) v)) kvs; m

let getprop_raw_pub e k = (match e with Map m -> (match omap_get m k with Some x -> x | None -> Noval) | _ -> Noval)
let entry_get e k = getprop_raw_pub e k
let entry_has e k = match e with Map m -> omap_has m k | _ -> false
let default_injdef_pub () =
  { d_meta = Noval; d_extra = Noval; d_errs = Noval; d_modify = None; d_handler = None;
    d_base = Noval; d_dparent = Noval; d_dpath = Noval; d_key = Noval }

let resolve_args entry =
  if entry_has entry "ctx" then [entry_get entry "ctx"]
  else if entry_has entry "args" then (
    match entry_get entry "args" with
    | List r ->
      (* ts's resolveArgs writes the live first arg back as entry.ctx, so a
         `match: {ctx: ...}` resolves for args-style entries too. Without it
         every such assertion reads null and asserts nothing. *)
      (match !r with
       | (Map _ as first) :: _ -> ignore (setprop entry (Str "ctx") first)
       | _ -> ());
      !r
    | _ -> [])
  else if entry_has entry "in" then [clone (entry_get entry "in")]
  else [Noval]

let check_result entry args res =
  let matched = ref false in
  (if entry_has entry "match" then begin
      do_match (entry_get entry "match")
        (omap_v ["in", entry_get entry "in"; "args", lst args;
                 "out", entry_get entry "res"; "ctx", entry_get entry "ctx"]);
      matched := true
    end);
  let out = entry_get entry "out" in
  if eqv out res then ()
  else if !matched && (out = Str nullmark || is_nullish out) then ()
  else raise (Struct_error (Printf.sprintf "Expected: %s, got: %s" (stringify out) (stringify res)))

let handle_error entry err =
  let msg = (match err with Struct_error m -> m | e -> Printexc.to_string e) in
  if entry_has entry "err" then begin
    let entry_err = entry_get entry "err" in
    if entry_err = Bool true || matchval entry_err (Str msg) then begin
      if entry_has entry "match" then
        do_match (entry_get entry "match")
          (omap_v ["in", entry_get entry "in"; "out", entry_get entry "res";
                   (* ts hands do_match the ERROR OBJECT, so a corpus
                      `match: {err: {message: ...}}` resolves; a bare string
                      leaves err.message reading null. *)
                   "ctx", entry_get entry "ctx";
                   "err", omap_v ["message", Str msg]])
    end else
      raise (Struct_error (Printf.sprintf "ERROR MATCH: [%s] <=> [%s]" (stringify entry_err) msg))
  end else raise err

let run_set ?(flags = []) group node subject =
  let flag_null = (match List.assoc_opt "null" flags with Some b -> b | None -> true) in
  let fixed = fix_json node flag_null in
  let testset = (match getprop fixed (Str "set") with List r -> !r | _ -> []) in
  List.iter (fun entry ->
      let name = js_string (entry_get entry "name") in
      try
        (if not (entry_has entry "out") && flag_null then ignore (setprop entry (Str "out") (Str nullmark)));
        let args = resolve_args entry in
        let res = fix_json (subject args) flag_null in
        ignore (setprop entry (Str "res") res);
        check_result entry args res;
        record group name true ""
      with
      | e ->
        (try handle_error entry e; record group name true ""
         with e2 -> record group name false
                      (match e2 with Struct_error m -> m | _ -> Printexc.to_string e2)))
    testset

let run_single group node actual_fn =
  try
    let expected = getprop_raw_pub node "out" in
    let actual = actual_fn (getprop_raw_pub node "in") in
    if eqv expected actual then record group "single" true ""
    else record group "single" false (Printf.sprintf "Expected: %s, got: %s" (stringify expected) (stringify actual))
  with e -> record group "single" false (match e with Struct_error m -> m | _ -> Printexc.to_string e)

(* ---------------- arg helpers ---------------- *)

let arg1 f = fun args -> f (match args with x :: _ -> x | [] -> Noval)
let vget vin k = match vin with Map m -> (match omap_get m k with Some x -> x | None -> Noval) | _ -> Noval
let vhas vin k = match vin with Map m -> omap_has m k | _ -> false
