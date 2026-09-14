(* VENDORED: @voxgig/plugin sdk-20260908-1556-0 (ocaml/src/order.ml) *)
(* Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* Ordering (§7) — one rule, one place.

   sdkgen grew two special cases in `makeOptions` (`test`, then
   `station`) and the third was not far off. This sort is the whole
   replacement, and the tiers are in this order for a reason:

     1 constraints   before/after edges, by ref or by name
     2 bands         integer, lower first, default 0
     3 declaration   ties break by `pos`

   CONSTRAINTS BEAT BANDS precisely so the correct tool wins when both
   are present. A band expresses a genuine cross-cutting layer; a
   constraint expresses a relationship between two specific things; and
   a band chosen by trial and error to fix an ordering bug is a bug
   wearing a number. *)

module V = Value

let bandof b =
  (* A NUMBER, not a numeric string. `order.band` accepting "1" was a
     surviving mutation in more than one port: the corpus pins the type
     because two ports disagreeing about whether "1" is a band is
     exactly the divergence a shared corpus exists to remove. *)
  let band = V.get (V.get b "order") "band" in
  if V.is_num band then V.as_num band else 0.0

let posof b =
  let p = V.get b "pos" in
  if V.is_num p then V.as_num p else 0.0

(* Band first (lower runs first), then `pos` — the position the
   DOCUMENT visibly states, not the order instances happened to load
   and not the incarnation `seq`. *)
let rank a b =
  let ab = bandof a and bb = bandof b in
  if ab <> bb then compare ab bb else compare (posof a) (posof b)

(* Was a constraint actually declared? An ABSENT one and an EMPTY LIST
   are both "no constraint"; only a non-empty spelling is an edge. *)
let declared spec =
  if V.is_list spec then 0 < V.len spec
  else if V.is_str spec then "" <> V.as_str spec
  else false

(* Matching is by REF, or by NAME across all of that definition's
   instances (§7) — which is the whole reason the two spellings
   exist. *)
let targets spec nodes =
  let specs = if V.is_list spec then V.items spec else [ spec ] in
  let hit = ref [] in
  List.iter
    (fun oneval ->
      if V.is_str oneval then begin
        let one = V.as_str oneval in
        List.iter
          (fun node ->
            let r = V.as_str (V.get node "ref") in
            if (not (List.mem r !hit)) && (r = one || Ref.refname r = one) then
              hit := !hit @ [ r ])
          (V.items nodes)
      end)
    specs;
  !hit

(* A PIN IS NOT A CONSTRAINT (§7).

   Constraints and bands are negotiable by definition — they are what
   plugins and documents say they want, and the sort's job is to
   satisfy them all. A pin is the host stating a structural invariant
   of its own architecture, which is a different kind of claim and must
   not lose a tie to a document.

   So a pin PLACES the binding at the named end, and an ordering that
   would move it away is `plugin_order_pinned` — rejected, not honoured
   into a broken wrap. *)
let applypin order edges pin =
  if not (V.is_map pin) then order
  else begin
    let out = ref (List.map V.as_str (V.items order)) in
    (* SORTED, not insertion order. A pin map is data — it can arrive
       from a host's own construction options in any order, and two
       names pinned to the same end are order-sensitive. Sorted is the
       one order every language agrees on, and `order/pin#two-names`
       pins it. *)
    List.iter
      (fun name ->
        let want = V.as_str (V.get pin name) in
        match List.find_opt (fun r -> Ref.refname r = name) !out with
        | None -> ()
        | Some r ->
          (* `first`/`outermost` is index 0; `last`/`innermost` is the
             end. §6.2 makes the first chain binding outermost, which
             is why the vocabulary is positional and why the two
             spellings pair this way. *)
          let wantfirst = "first" = want || "outermost" = want in
          let rest = List.filter (fun x -> x <> r) !out in
          out := (if wantfirst then r :: rest else rest @ [ r ]))
      (V.sortedkeys pin);

    (* Now check that the placement did not break a constraint. This is
       the half that makes a pin a rejection rather than an override:
       the host wins on position, but it does not get to silently
       discard a relationship a plugin declared. *)
    let index = V.vmap () in
    List.iteri (fun i r -> V.set index r (V.vnum (float_of_int i))) !out;
    List.iter
      (fun from ->
        List.iter
          (fun tov ->
            let t = V.as_str tov in
            if V.as_num (V.get index from) > V.as_num (V.get index t) then begin
              let d = V.vmap () in
              V.set d "before" (V.vstr from);
              V.set d "after" (V.vstr t);
              Types.fail "plugin_order_pinned"
                ("a pin would move a binding an ordering constrains: " ^ from
                 ^ " must precede " ^ t)
                ~details:d
            end)
          (V.items (V.get edges from)))
      (V.sortedkeys edges);

    V.oflist (List.map V.vstr !out)
  end

let resolveorder bindings pin =
  let nodes = V.items bindings in
  let n = List.length nodes in

  let byref = V.vmap () in
  List.iter (fun b -> V.set byref (V.as_str (V.get b "ref")) b) nodes;

  (* Constraints are edges. A constraint naming an ABSENT binding is
     satisfied VACUOUSLY (§7) — a plugin ordered `after: 'test'` must
     load in a host with no test plugin. That is sdkgen's __after__
     behaviour, kept. *)
  let edges = V.vmap () in
  List.iter (fun b -> V.set edges (V.as_str (V.get b "ref")) (V.vlist ())) nodes;

  List.iter
    (fun b ->
      let bref = V.as_str (V.get b "ref") in
      let o = V.get b "order" in
      let after = V.get o "after" and before = V.get o "before" in
      if declared after then
        List.iter (fun t -> V.push (V.get edges t) (V.vstr bref))
          (targets after bindings);
      if declared before then
        List.iter (fun t -> V.push (V.get edges bref) (V.vstr t))
          (targets before bindings))
    nodes;

  (* Stable topological sort. *)
  let indeg = V.vmap () in
  List.iter (fun b -> V.set indeg (V.as_str (V.get b "ref")) (V.vnum 0.0)) nodes;
  List.iter
    (fun from ->
      List.iter
        (fun tov ->
          let t = V.as_str tov in
          V.set indeg t (V.vnum (V.as_num (V.get indeg t) +. 1.0)))
        (V.items (V.get edges from)))
    (V.keys edges);

  let ready =
    ref (List.filter
           (fun b -> 0.0 = V.as_num (V.get indeg (V.as_str (V.get b "ref"))))
           nodes)
  in
  let out = ref [] in
  while [] <> !ready do
    let sorted = List.stable_sort rank !ready in
    let next = List.hd sorted in
    ready := List.tl sorted;
    let nref = V.as_str (V.get next "ref") in
    out := !out @ [ nref ];
    List.iter
      (fun tov ->
        let t = V.as_str tov in
        let d = V.as_num (V.get indeg t) -. 1.0 in
        V.set indeg t (V.vnum d);
        if 0.0 = d then ready := !ready @ [ V.get byref t ])
      (V.items (V.get edges nref))
  done;

  if List.length !out <> n then begin
    let stuck =
      List.filter_map
        (fun b ->
          let r = V.as_str (V.get b "ref") in
          if List.mem r !out then None else Some r)
        nodes
    in
    Types.fail "plugin_order_cycle"
      ("before/after constraints cycle: " ^ String.concat " -> " stuck)
      ~details:(Types.details1 "cycle" (V.oflist (List.map V.vstr stuck)))
  end;

  applypin (V.oflist (List.map V.vstr !out)) edges pin
