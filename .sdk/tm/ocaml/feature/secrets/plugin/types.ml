(* VENDORED: @voxgig/plugin sdk-20260908-1556-0 (ocaml/src/types.ml) *)
(* Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* Errors, and the raise mechanism (§12).

   A REAL EXCEPTION. The canonical raises: a failing call abandons the
   rest of the function, and the corpus is full of entries that assert
   exactly what survived a raise mid-sequence (`resource/unwind`,
   `lifecycle/fail`). OCaml has exceptions, so the port uses them —
   unlike `c`, which has to build the same semantics out of
   `setjmp`/`longjmp` and an arena.

   Ports compare by CODE and never by message: wording is a port's own
   business. The FORMAT is pinned, because a parseable message is what
   makes a log searchable across twenty languages. *)

module V = Value

type error = {
  code : string;
  text : string;
  details : V.t;
  message : string;
}

exception Plugin_error of error

(* §12's detail fields, IN THIS FIXED ORDER. The order is part of the
   contract: an earlier draft named six fields while other sections
   promised diagnostics with nowhere to go, which would have left each
   port inventing its own order and breaking message parity. *)
let detail_order =
  [ "host"; "ref"; "name"; "tag"; "point"; "key"; "capability";
    "range"; "version"; "match"; "candidates"; "cycle"; "holders";
    "refs"; "path"; "cause" ]

let formaterror code text details =
  (* Values render as COMPACT JSON, so a value containing a space or a
     bracket cannot break the parse and a list renders as an array. The
     bracket is absent entirely when no field applies. *)
  let parts =
    List.filter_map
      (fun k ->
        if V.has details k then Some (k ^ "=" ^ V.json (V.get details k))
        else None)
      detail_order
  in
  let head = "plugin/" ^ code ^ ": " ^ text in
  match parts with
  | [] -> head
  | _ -> head ^ " [" ^ String.concat " " parts ^ "]"

let fail ?details code text =
  let details = match details with Some d -> d | None -> V.vmap () in
  raise
    (Plugin_error
       { code; text; details; message = formaterror code text details })

let details1 k v =
  let d = V.vmap () in
  V.set d k v;
  d

let details2 k1 v1 k2 v2 =
  let d = V.vmap () in
  V.set d k1 v1;
  V.set d k2 v2;
  d

(* Deep merge, struct's semantics: maps merge, everything else
   replaces. §16 permits voxgig/struct for this and OCaml has no port
   of it. *)
let rec mergevalue a b =
  if not (V.is_map a && V.is_map b) then b
  else begin
    let out = V.vmap () in
    List.iter (fun k -> V.set out k (V.get a k)) (V.keys a);
    List.iter
      (fun k ->
        let bv = V.get b k in
        let av = V.get out k in
        if V.is_map av && V.is_map bv then V.set out k (mergevalue av bv)
        else V.set out k bv)
      (V.keys b);
    out
  end

(* §11.1's partial match: every leaf in `want` must be present and
   equal in `have`; keys not mentioned are not checked. *)
let rec matchvalue want have =
  if V.is_null want then true
  else if V.is_map want then
    V.is_map have
    && List.for_all
         (fun k -> V.has have k && matchvalue (V.get want k) (V.get have k))
         (V.keys want)
  else V.same want have
