(* Univec SDK omni runner smoke test.
 *
 * Smoke tests for the VENDORED omni runner itself, and for the two
 * load-bearing decisions in Omni_resolver. A runner that cannot FAIL a bad
 * entry would turn every corpus suite vacuously green, so the failure paths
 * are pinned here, not just the happy one. (OCaml peer of ts's
 * test/omni.test.ts, py's test_omni_smoke.py and lua's
 * test/omni_smoke_test.lua.)
 *
 * The spec is built IN MEMORY, in omni's own value model — no fixture file,
 * and no OMNI block (lenient v0, like the shared corpus).
 *)

module O = Omni
module R = Omni_resolver
module V = Voxgig_struct

(* ---------------- a tiny assertion harness ---------------- *)

let npass = ref 0
let nfail = ref 0

let check (name : string) (cond : bool) : unit =
  if cond then incr npass
  else begin
    incr nfail;
    print_endline ("FAIL " ^ name)
  end

let contains (hay : string) (needle : string) : bool =
  let hl = String.length hay and nl = String.length needle in
  let rec go at = if at + nl > hl then false
    else if String.sub hay at nl = needle then true else go (at + 1) in
  nl = 0 || go 0

let onefailure (name : string) (r : R.run) (want : string) : unit =
  match r.R.failures with
  | [ message ] ->
    check (name ^ ": failure mentions " ^ want) (contains message want)
  | other ->
    check (name ^ ": expected exactly one failure, got "
           ^ string_of_int (List.length other)) false

(* ---------------- the in-memory spec ---------------- *)

let num n = O.Num (float_of_int n)

let makespec () =
  O.JMap [ ("primary", O.JMap [ ("smoke", O.JMap [

    ("basic", O.JMap [ ("set", O.JList [
      O.JMap [ ("in", num 1); ("out", num 2) ];
      O.JMap [ ("in", num 41); ("out", num 42) ] ]) ]);

    ("bad", O.JMap [ ("set", O.JList [
      O.JMap [ ("in", num 1); ("out", num 999) ] ]) ]);

    ("err", O.JMap [ ("set", O.JList [
      O.JMap [ ("in", num 0); ("err", O.Str "zero refused") ] ]) ]);

    ("empty", O.JMap [ ("set", O.JList []) ]);

    (* Resolver decision 2: a subject that MUTATES its argument, which
     * `match.args` then asserts on. Without the write-back this passes
     * vacuously - the assertion would read the unmutated input. *)
    ("mutate", O.JMap [ ("set", O.JList [
      O.JMap [ ("in", O.JMap [ ("x", num 1) ]);
               ("match", O.JMap [ ("args", O.JMap [ ("0", O.JMap [ ("x", num 2) ]) ]) ]);
               ("out", num 2) ] ]) ]);

    (* Resolver decision 3: `match: {ctx: ...}` must read the POST-call ctx.
     * omni's own `entry.ctx` is a pre-call copy, so without the retarget
     * this entry fails. *)
    ("ctx", O.JMap [ ("set", O.JList [
      O.JMap [ ("ctx", O.JMap [ ("a", num 1) ]);
               ("match", O.JMap [ ("ctx", O.JMap [ ("b", num 2) ]) ]);
               ("out", num 1) ] ]) ]);

  ]) ]) ]

let pack () : R.run = R.make_run_spec (makespec ()) "smoke"

(* ---------------- subjects ---------------- *)

let inc (v : V.value) : V.value =
  match v with
  | V.Num n -> if 0.0 = n then failwith "smoke: zero refused" else V.Num (n +. 1.0)
  | other -> other

let identity (v : V.value) : V.value = v

(* Mutates its argument in place and returns the new value. *)
let bump (v : V.value) : V.value =
  ignore (V.setprop v (V.Str "x") (V.Num 2.0));
  V.Num 2.0

(* Does NOT mutate: the negative control for decision 2. *)
let nobump (_v : V.value) : V.value = V.Num 2.0

(* Writes a key onto the ctx map AFTER it was handed over: the positive
 * control for decision 3. *)
let ctxwrite (args : V.value array) : V.value =
  ignore (V.setprop args.(0) (V.Str "b") (V.Num 2.0));
  V.Num 1.0

let ctxnowrite (_args : V.value array) : V.value = V.Num 1.0

(* ---------------- the tests ---------------- *)

let () =
  (* A correct subject passes, and every case is counted. *)
  let r = pack () in
  R.runset r "basic" (R.getset r ["basic"]) inc;
  check "basic: no failures" ([] = r.R.failures);
  check "basic: both cases ran" (2 = r.R.pass);

  (* A wrong result FAILS, and the resolver records it rather than
   * swallowing it. This is the anti-vacuity check the rollout exists for. *)
  let r = pack () in
  R.runset r "bad" (R.getset r ["bad"]) inc;
  onefailure "bad" r "result mismatch";
  check "bad: no case counted as passing" (0 = r.R.pass);

  (* An expected error is matched. *)
  let r = pack () in
  R.runset r "err" (R.getset r ["err"]) inc;
  check "err: expected error matched" ([] = r.R.failures);
  check "err: case counted" (1 = r.R.pass);

  (* An expected error that does NOT occur must fail. *)
  let r = pack () in
  R.runset r "err" (R.getset r ["err"]) identity;
  onefailure "err-missing" r "expected error did not occur";

  (* A group absent from the spec is NAMED, never a silent pass. *)
  let r = pack () in
  R.runset r "nosuch" (R.getset r ["nosuch"]) inc;
  check "absent: no failures" ([] = r.R.failures);
  check "absent: nothing counted" (0 = r.R.pass);
  check "absent: named as skipped" (1 = List.length r.R.skipped);

  (* An EMPTY set is likewise named, not counted as a pass. *)
  let r = pack () in
  R.runset r "empty" (R.getset r ["empty"]) inc;
  check "empty: nothing counted" (0 = r.R.pass);
  check "empty: named as skipped" (1 = List.length r.R.skipped);

  (* Decision 2: argument mutation reaches `match.args`. *)
  let r = pack () in
  R.runset r "mutate" (R.getset r ["mutate"]) bump;
  check "mutate: write-back reaches match.args" ([] = r.R.failures);
  check "mutate: case counted" (1 = r.R.pass);

  let r = pack () in
  R.runset r "mutate" (R.getset r ["mutate"]) nobump;
  onefailure "mutate-missing" r "match failed at args.0.x";

  (* Decision 3: `match.ctx` reads the POST-call ctx. *)
  let r = pack () in
  R.runset_args r "ctx" (R.getset r ["ctx"]) ctxwrite;
  check "ctx: retarget reaches post-call ctx" ([] = r.R.failures);
  check "ctx: case counted" (1 = r.R.pass);

  let r = pack () in
  R.runset_args r "ctx" (R.getset r ["ctx"]) ctxnowrite;
  onefailure "ctx-missing" r "match failed at args.0.b";

  Printf.printf "\nOMNI SMOKE: PASS %d  FAIL %d\n" !npass !nfail;
  if 0 < !nfail then exit 1
