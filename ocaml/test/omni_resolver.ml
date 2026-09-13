(* The corpus test runner: vendored @voxgig/omni driven through its NATIVE
 * API (`Omni.make_runner` / `runpack.runsetflags_args`), presented to the
 * corpus suites in the shape they already use (`spec`, `getset`, `runset`,
 * `runset_args`, `report`). No compat shim is vendored: the adapter below IS
 * the whole bridge, per language, per the vendor-tag rollout
 * (docs/design/vendor-tag-rollout.md, Decision 4). It supersedes the whole of
 * the retired test/corpus_runner.ml — engine AND the handful of value
 * helpers that sat beside it, which are re-homed here rather than left in a
 * file whose name no longer describes anything.
 *
 * It is the OCaml peer of tm/rust/tests/omni_resolver/mod.rs and
 * tm/java/test/OmniResolver.java: the portable answer for a statically typed
 * port with no reflection — omni's `provider` is closure-based, so nothing
 * in omni ever has to name this SDK's types.
 *
 * OCaml-specific decisions, each load-bearing:
 *
 * 1. TWO VALUE MODELS, ONE CONVERSION PAIR. `Omni.json` and the SDK's
 *    `Voxgig_struct.value` are different variants, so every crossing is an
 *    explicit `tostruct` / `toomni`. `Omni.Absent` <-> `Voxgig_struct.Noval`
 *    and `Omni.Null` <-> `Voxgig_struct.Null` keep the two no-value states
 *    the corpus distinguishes apart — which is also why OCaml needs neither
 *    go's `novalargs` spec rewrite nor lua/php's compat shim for the
 *    corpus's ZERO-ARGUMENT entries. An entry with no `in`/`args`/`ctx`
 *    reaches the subject as one `Omni.Absent`, and that becomes exactly this
 *    port's own no-value, `Noval` — so `typify` answers T_NOVAL where a null
 *    would answer T_NULL, and the arity correction is structural rather than
 *    a special case.
 *
 * 2. ARGUMENTS ARE WRITTEN BACK. `Omni.subject_args` (`json array -> json`)
 *    is the channel omni provides for a subject that MUTATES its arguments,
 *    which `match: {args: ...}` then asserts on — `struct/minor/setpath`
 *    (7 entries) and `struct/merge/integrity` (6) turn on it. Decision 1
 *    handed the subject a CONVERTED COPY, and `Omni.json` is immutable, so
 *    every subject here runs through `runsetflags_args` and the wrapper
 *    converts the (possibly mutated) values back into omni's own array
 *    after the call. A dynamic port's shim gets this free from shared object
 *    identity; OCaml cannot.
 *
 * 3. `match: {ctx: ...}` IS RETARGETED ONTO `match: {args: {"0": ...}}`.
 *    The one place this port cannot follow canonical omni as written, and a
 *    VALUE-SEMANTICS consequence, not a choice. omni's `drive` stores the
 *    contextified first argument as `entry.ctx` and as `args[0]` — two
 *    copies of an immutable value — and `checkresult` reads `entry.ctx` for
 *    the ctx base. A subject's post-call writes (decision 2) can never reach
 *    that copy, and NINE `primary` entries assert exactly the post-call
 *    state (makeRequest, makeResponse, makeSpec, param, prepareAuth,
 *    resultBody, resultHeaders, transformRequest, transformResponse).
 *    `args[0]` IS the ctx of a ctx entry (omni itself sets
 *    `args = [entry.ctx]`), and the runner reads that array back after an
 *    args-subject call — so moving the assertion from `ctx` to `args.0`
 *    reads the SAME map, post-call, and preserves every leaf: nothing is
 *    dropped, weakened or skipped. `retargetctx` below does that rewrite on
 *    the spec handed to the engine. Rust and Swift face the identical
 *    problem and answer it identically; the upstream fix is for the port's
 *    `drive` to re-point `entry.ctx` at the returned `args[0]`, the way JS
 *    object identity does implicitly — a follow-up, never a hand-edit of a
 *    vendored file.
 *
 * 4. KEY ORDER AND NUMBERS NEED NOTHING. omni's OCaml port models a map as
 *    an ordered assoc list built in document order by its own parser, and
 *    compares maps order-independently (`deepequal`); this port's `omap` is
 *    also insertion-ordered. Both read every JSON number as `float`. So the
 *    round trip is lossless in both directions — unlike rust (BTreeMap) or
 *    go/csharp/java (integral doubles).
 *
 * 5. SUBJECT FAILURES ARRIVE AS `Failure`. omni's `errmessage` understands
 *    `Omni_error` and `Failure` and renders anything else through
 *    `Printexc`, which would turn `Voxgig_struct.Struct_error "Expected
 *    string, ..."` into `Voxgig_struct.Struct_error("Expected string, ...")`
 *    and break the 50-odd `validate`/`transform` entries that match on the
 *    message. So the wrappers translate `Struct_error` to `Failure`.
 *    `Omni_error` is deliberately NOT used: omni re-raises that as a runner
 *    error rather than treating it as a candidate for an `err` expectation.
 *    An SDK-branded error is translated the same way at the primary suite's
 *    call site, which is where `Sdk_types` is in scope.
 *
 * 6. FAILURES ARE ACCUMULATED, NOT RAISED. omni stops a group at its first
 *    bad entry and raises; the corpus suites report the whole corpus in one
 *    run. `drive` records the message and carries on, so one run still names
 *    every broken GROUP. A group that is ABSENT from the corpus, or present
 *    with an empty set, is recorded in `skipped` and printed by `report` —
 *    named out loud, never a silent vacuous pass. *)

module O = Omni
module V = Voxgig_struct

(* The sentinels, under the names the corpus suites already use. *)
let nullmark = O.nullmark
let undefmark = O.undefmark
let existsmark = O.existsmark

(* ---------------- value model conversion (decision 1) ---------------- *)

let rec tostruct (value : O.json) : V.value =
  match value with
  | O.Absent -> V.Noval
  | O.Null -> V.Null
  | O.Bool flag -> V.Bool flag
  | O.Num entry -> V.Num entry
  | O.Str text -> V.Str text
  | O.JList entries -> V.List (ref (List.map tostruct entries))
  | O.JMap entries -> V.Map { V.entries = List.map (fun (k, e) -> (k, tostruct e)) entries }

let rec toomni (value : V.value) : O.json =
  match value with
  | V.Noval -> O.Absent
  | V.Null -> O.Null
  | V.Bool flag -> O.Bool flag
  | V.Num entry -> O.Num entry
  | V.Str text -> O.Str text
  | V.List entries -> O.JList (List.map toomni !entries)
  | V.Map m -> O.JMap (List.map (fun (k, e) -> (k, toomni e)) m.V.entries)
  (* Neither can appear in a JSON corpus, and no subject here returns one;
   * rendered rather than dropped so an unexpected one FAILS visibly instead
   * of vanishing into a null. *)
  | V.Func _ -> O.Str "[Function]"
  | V.Sentinel tag -> O.Str tag

(* ---------------- value helpers (re-homed from corpus_runner) -------- *)

(* Raw property read: absent answers Noval, never an alt. *)
let getp (value : V.value) (key : string) : V.value =
  match value with
  | V.Map m -> (match V.omap_get m key with Some x -> x | None -> V.Noval)
  | _ -> V.Noval

let hasp (value : V.value) (key : string) : bool =
  match value with V.Map m -> V.omap_has m key | _ -> false

let omap_v (pairs : (string * V.value) list) : V.value =
  let m = V.empty_map () in
  List.iter (fun (k, v) -> ignore (V.setprop m (V.Str k) v)) pairs;
  m

let default_injdef () : V.injdef =
  { V.d_meta = V.Noval; V.d_extra = V.Noval; V.d_errs = V.Noval; V.d_modify = None;
    V.d_handler = None; V.d_base = V.Noval; V.d_dparent = V.Noval; V.d_dpath = V.Noval;
    V.d_key = V.Noval }

(* ---------------- the run ------------------------------------------- *)

type run = {
  pack : O.runpack;
  mutable pass : int;             (* corpus CASES executed and passed *)
  mutable groups : int;           (* corpus groups driven *)
  mutable failures : string list;
  mutable skipped : string list;
}

(* Every hook is optional and this SDK needs none of them: subjects are
 * passed explicitly per group (so `subject` is unused), the primary suite
 * builds its own per-section client from the corpus DEF.setup block (so
 * `client`/`inject` are unused), contexts stay maps across the runner
 * (decision 3, so `contextify` is unused), and no corpus entry asserts on
 * an error CODE, so omni's own {name,message} errify is exactly right. *)
let provider = O.empty_provider

let make_run_spec (spec : O.json) (name : string) : run =
  let runner = O.make_runner_spec spec provider in
  { pack = runner name None; pass = 0; groups = 0; failures = []; skipped = [] }

let make_run (testfile : string) (name : string) : run =
  make_run_spec (O.loadspec testfile) name

(* The resolved section of the spec (omni's `primary.<name>`, then `<name>`,
 * then the whole spec). *)
let spec (r : run) : O.json = r.pack.O.spec

(* A named group, by a path of keys from the resolved section. *)
let getset (r : run) (keys : string list) : O.json =
  List.fold_left (fun acc key -> O.jget acc key) (spec r) keys

(* A corpus group authored as ONE `{in, out}` pair rather than a set —
 * `merge/basic`, `inject/basic`, `transform/basic`, `walk/log`. Wrapped into
 * a one-entry set so it runs through the SAME engine as everything else
 * instead of a bespoke code path beside it. `out` selects a sub-path of the
 * authored `out` (walk/log asserts only on `out.after`). *)
let single ?(out = []) (node : O.json) : O.json =
  let expected = List.fold_left (fun acc key -> O.jget acc key) (O.jget node "out") out in
  O.JMap [ ("set", O.JList [ O.JMap [ ("in", O.jget node "in"); ("out", expected) ] ]) ]

(* ---------------- decision 3: retarget match.ctx --------------------- *)

let retargetctx (testspec : O.json) : O.json =
  match testspec with
  | O.JMap fields -> (
    match O.jget testspec "set" with
    | O.JList entries ->
      let rewrite raw =
        let check = O.jget raw "match" in
        if O.ismap raw && O.ismap check && O.jhas check "ctx" && not (O.jhas check "args")
           && (O.jhas raw "ctx" || O.jhas raw "args")
        then begin
          (* Drop the original leaf: it would read the stale pre-call copy
           * omni keeps in `entry.ctx`. *)
          let trimmed =
            match check with
            | O.JMap kv -> O.JMap (List.filter (fun (k, _) -> k <> "ctx") kv)
            | other -> other
          in
          let retargeted = O.jset trimmed "args" (O.JMap [ ("0", O.jget check "ctx") ]) in
          O.jset raw "match" retargeted
        end
        else raw
      in
      let rewritten = O.JList (List.map rewrite entries) in
      O.JMap (List.map (fun (k, v) -> if k = "set" then (k, rewritten) else (k, v)) fields)
    | _ -> testspec)
  | _ -> testspec

(* ---------------- subject wrappers (decisions 2 and 5) --------------- *)

let guard (call : unit -> V.value) : V.value =
  try call () with V.Struct_error message -> raise (Failure message)

let wrap1 (subject : V.value -> V.value) : O.json array -> O.json =
 fun cells ->
  let first = if 0 < Array.length cells then tostruct cells.(0) else V.Noval in
  let res = guard (fun () -> subject first) in
  if 0 < Array.length cells then cells.(0) <- toomni first;
  toomni res

let wrapargs (subject : V.value array -> V.value) : O.json array -> O.json =
 fun cells ->
  let vals = Array.map tostruct cells in
  let res = guard (fun () -> subject vals) in
  Array.iteri (fun index v -> cells.(index) <- toomni v) vals;
  toomni res

(* ---------------- driving one group ---------------------------------- *)

let entrycount (node : O.json) : int =
  match O.jget node "set" with O.JList entries -> List.length entries | _ -> -1

let oneline (text : string) : string =
  String.concat " | " (String.split_on_char '\n' text)

let drive (r : run) (nullflag : bool) (label : string) (node : O.json)
    (call : O.json array -> O.json) : unit =
  let count = entrycount node in
  if count <= 0 then
    (* Absent, malformed, or empty. NAMED, never silent: a group that stopped
     * running is the failure mode the vendored engine exists to prevent. *)
    r.skipped <- Printf.sprintf "%s (%s)" label
        (if O.isabsent node then "absent from corpus"
         else if count = 0 then "empty set" else "no set")
      :: r.skipped
  else begin
    r.groups <- r.groups + 1;
    let flags = { O.null = nullflag; O.name = Some label } in
    let usespec = retargetctx node in
    match r.pack.O.runsetflags_args usespec flags call with
    | () -> r.pass <- r.pass + count
    | exception O.Omni_error message -> r.failures <- oneline message :: r.failures
  end

(* Run one group whose subject takes the entry's single argument. *)
let runset (r : run) ?(nullflag = true) (label : string) (node : O.json)
    (subject : V.value -> V.value) : unit =
  drive r nullflag label node (wrap1 subject)

(* Run one group whose subject takes omni's whole argument array. This is the
 * shape the `primary` suite needs: a `ctx` entry arrives as `args.(0)`, a
 * MAP, which the call site turns into a live context and writes the
 * observable state back into (decisions 2 and 3). *)
let runset_args (r : run) ?(nullflag = true) (label : string) (node : O.json)
    (subject : V.value array -> V.value) : unit =
  drive r nullflag label node (wrapargs subject)

(* ---------------- reporting ------------------------------------------ *)

let report (r : run) (prefix : string) : unit =
  List.iter (fun m -> print_endline ("FAIL " ^ m)) (List.rev r.failures);
  if [] <> r.skipped then
    List.iter (fun s -> print_endline ("SKIP " ^ s)) (List.rev r.skipped);
  Printf.printf "\n%sPASS %d  FAIL %d\n" prefix r.pass (List.length r.failures);
  Printf.printf "%sGROUPS %d  SKIPPED %d\n" prefix r.groups (List.length r.skipped);
  (* A run that executes nothing is not a pass. *)
  if 0 = r.pass then begin
    print_endline (prefix ^ "the corpus executed no cases");
    exit 1
  end;
  if [] <> r.failures then exit 1
