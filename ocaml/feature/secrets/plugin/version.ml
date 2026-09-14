(* VENDORED: @voxgig/plugin sdk-20260908-1556-0 (ocaml/src/version.ml) *)
(* Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* Versions and ranges (§11.2).

   TWO FIELDS AND ONE PREDICATE. A capability declares `version`, a
   concrete version. A requirement declares `range`. A requirement is
   satisfied when the names match, the `match` passes, and the
   provider's `version` falls inside the requirement's `range`. That is
   the whole rule — there is no third field and no second comparison. *)

module V = Value

(* A COMPONENT IS BOUNDED, like a ref is (§4's 1024).

   The grammar admits an unbounded digit sequence, and every language
   then disagrees about what happens past its integer range: JavaScript
   silently loses precision, Go's Atoi errors (and a port ignoring that
   gets 0), C overflows, Python is exact. `satisfies("0",
   "9223372036854775808")` was false in the canonical and true in go,
   from the same corpus.

   2^31-1 because every port has a signed 32-bit integer, and no real
   version has ever needed more. Found by review of the go port. *)
let component_max = 2147483647

(* `^(\d+)(?:\.(\d+))?(?:\.(\d+))?$`, by hand: three components, digits
   only, no leading sign, no empty component. Written out rather than
   handed to `Str` because the bound above has to be checked per
   component anyway, and a regex that matched then needed re-scanning
   would be the worse of both. Answers None for "not a version", and
   Some (parts, overflow). *)
let parse3 s =
  let n = String.length s in
  if 0 = n then None
  else begin
    let out = [| 0; 0; 0 |] in
    let overflow = ref false in
    let i = ref 0 in
    let bad = ref false in
    let stopped = ref false in
    let part = ref 0 in
    while (not !bad) && (not !stopped) && !part < 3 do
      if !i >= n then (if 0 < !part then stopped := true else bad := true)
      else begin
        if 0 < !part then
          if '.' <> s.[!i] then bad := true else incr i;
        if not !bad then begin
          let start = !i in
          let acc = ref 0 in
          while !i < n && '0' <= s.[!i] && s.[!i] <= '9' do
            if not !overflow then begin
              acc := (!acc * 10) + (Char.code s.[!i] - Char.code '0');
              if component_max < !acc then overflow := true
            end;
            incr i
          done;
          (* An empty component is not a number. *)
          if start = !i then bad := true else out.(!part) <- !acc;
          incr part
        end
      end
    done;
    if !bad then None
    else if (not !stopped) && !i <> n then None
    else Some (out, !overflow)
  end

let triple n =
  V.oflist [ V.vnum (float_of_int n.(0)); V.vnum (float_of_int n.(1));
             V.vnum (float_of_int n.(2)) ]

let parserange range =
  if (not (V.is_str range)) || "" = V.as_str range then
    Types.fail "plugin_bad_range"
      ("invalid range: " ^ if V.is_str range then V.as_str range else "")
      ~details:
        (Types.details1 "range" (if V.is_null range then V.vnull else range));
  let s = V.as_str range in
  (* Two forms and no more (§11.2):
       '2.1'   >= 2.1.0 and < 3.0.0
       '~2.1'  >= 2.1.0 and < 2.2.0 *)
  let tilde = '~' = s.[0] in
  let body = if tilde then String.sub s 1 (String.length s - 1) else s in
  match parse3 body with
  | None -> Types.fail "plugin_bad_range" ("invalid range: " ^ s)
              ~details:(Types.details1 "range" range)
  | Some (_, true) ->
    Types.fail "plugin_bad_range"
      ("version component out of range in " ^ s)
      ~details:(Types.details1 "range" range)
  | Some (n, false) ->
    let lo = [| n.(0); n.(1); n.(2) |] in
    let hi =
      if tilde then [| n.(0); n.(1) + 1; 0 |] else [| n.(0) + 1; 0; 0 |]
    in
    let out = V.vmap () in
    V.set out "lo" (triple lo);
    V.set out "hi" (triple hi);
    out

let parseversion version =
  if not (V.is_str version) then
    Types.fail "plugin_bad_range" "invalid version"
      ~details:
        (Types.details1 "version"
           (if V.is_null version then V.vnull else version));
  let s = V.as_str version in
  match parse3 s with
  (* `plugin_bad_range` either way — the same code the rest of the
     grammar's failures use, because "this is not a version I can
     compare" is one fact however it went wrong. *)
  | None -> Types.fail "plugin_bad_range" ("invalid version: " ^ s)
              ~details:(Types.details1 "version" version)
  | Some (_, true) ->
    Types.fail "plugin_bad_range"
      ("version component out of range in " ^ s)
      ~details:(Types.details1 "version" version)
  | Some (n, false) -> triple n

let vercmp a b =
  let rec go i =
    if 3 <= i then 0
    else
      let x = V.as_num (V.at a i) and y = V.as_num (V.at b i) in
      if x <> y then if x < y then -1 else 1 else go (i + 1)
  in
  go 0

let satisfies version range =
  let v = parseversion version in
  let r = parserange range in
  0 <= vercmp v (V.get r "lo") && 0 > vercmp v (V.get r "hi")

(* `satisfies` for the internal callers that treat an unparseable
   version or range as "does not satisfy" — Capability and Graph, both
   of which run over data the corpus has already admitted. *)
let satisfiesq version range =
  try satisfies version range with Types.Plugin_error _ -> false
