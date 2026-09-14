(* VENDORED: @voxgig/plugin sdk-20260908-1556-0 (ocaml/src/depend.ml) *)
(* Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* Dependency cardinality, policy, and the restart graph (§11.3).

   TWO AXES, BOTH DECLARED BY THE DEFINITION THAT HAS THE REQUIREMENT,
   because only it knows what it can cope with:

                  | static (default)          | dynamic
     -------------|---------------------------|--------------------------
     mandatory    | unmet -> pending;         | unmet -> pending;
     (default)    | lost  -> pending,         | lost  -> STAYS LIVE,
                  |          recursively      |          notified
     -------------|---------------------------|--------------------------
     optional:true| never gates activation;   | never gates activation;
                  | a change deactivates and  | a change is a
                  | reactivates               | notification, nothing else

   `dynamic` means the plugin has said, IN WRITING, that it can survive
   its provider being swapped underneath it. It is not the default
   because most plugins cannot, and the cost of wrongly assuming they
   can is a live instance holding a dead reference. *)

module V = Value

(* A bare string is shorthand for `{name}`. *)
let normrequire r =
  if V.is_str r then begin
    let out = V.vmap () in
    V.set out "name" r;
    out
  end
  else if V.is_map r then r
  else V.vmap ()

(* BOTH AXES ARE READ AT TWO LEVELS, AND THE PER-REQUIREMENT ONE WINS.

   The instance-level `policy` and `optional` list are how a DOCUMENT
   states the axis without editing the definition, and they apply to
   every requirement. The per-requirement form is strictly more
   expressive: an instance that is `static` on its store and `dynamic`
   on its metrics cannot be written at all at the instance level, and
   that is the ordinary case rather than an exotic one.

   `optional` UNIONS rather than overriding — both spellings say this
   requirement need not gate activation, and there is no reading under
   which one of them means "actually, mandatory". *)
let requirements options =
  let raw = V.get options "requires" in
  let marked = V.get options "optional" in
  let fallback = V.get options "policy" in
  V.oflist
    (List.map
       (fun item ->
         let r = normrequire item in
         let o = V.vmap () in
         List.iter (fun k -> V.set o k (V.get r k)) (V.keys r);
         let opt =
           V.truthy (V.get r "optional")
           || (V.is_list marked
              && List.exists (fun m -> V.same m (V.get r "name"))
                   (V.items marked))
         in
         if opt then V.set o "optional" (V.vbool true);
         if V.is_null (V.get o "policy") && not (V.is_null fallback) then
           V.set o "policy" fallback;
         o)
       (V.items raw))

(* Does losing this requirement's SELECTED provider restart the
   consumer? The mandatory ones under `static`, and the `static`
   optional ones — both make a capability change deactivate and
   reactivate. `dynamic` never restarts. *)
let restartsonloss r =
  let p = V.get r "policy" in
  "dynamic" <> (if V.is_str p then V.as_str p else "static")

(* Does an unmet requirement keep the consumer out of `live`?

   CARDINALITY ALONE DECIDES THIS, NOT POLICY. `dynamic` is a statement
   about surviving a SWAP, not about starting without the thing at all
   — a mandatory-dynamic consumer still waits in `pending` for its
   first provider. Conflating the two would let a plugin that declared
   it can cope with replacement activate with nothing to call. *)
let gatesactivation r = true <> V.as_bool (V.get r "optional")

(* Edges that can cause a restart, which is exactly the set a cycle
   must be detected over (§11.3): the mandatory requirements AND THE
   `static` OPTIONAL ONES, because both make a capability change
   deactivate and reactivate the consumer — and a cycle of restarts
   does not settle.

   ONLY `dynamic` OPTIONAL EDGES ARE EXCLUDED, and they are the ones
   the exclusion was for. An earlier draft of §11.3 excluded EVERY
   optional edge and thereby admitted the non-terminating case it was
   trying to permit. *)
let restartcausing r = gatesactivation r || restartsonloss r

let dependencycycle nodes =
  (* TWO INDEXES, NOT ONE MERGED MAP. Capability names and refs are
     matched differently — a capability by its exact name, a ref
     through the canonical spelling (§4 rule 5) — and one map keyed by
     both can only do one of them. Keyed by both and looked up raw, a
     cycle spelled `a$`/`b$` finds no providers and EVADES the
     load-time check that exists to catch a non-terminating
     reconcile. *)
  let bycap = V.vmap () in
  let isref = V.vmap () in
  List.iter
    (fun n ->
      let nref = V.as_str (V.get n "ref") in
      V.set isref nref (V.vbool true);
      List.iter
        (fun capv ->
          let cap = V.as_str capv in
          let l = V.get bycap cap in
          let l =
            if V.is_null l then (let x = V.vlist () in V.set bycap cap x; x)
            else l
          in
          V.push l (V.vstr nref))
        (V.items (V.get n "provides")))
    (V.items nodes);

  let edges = V.vmap () in
  List.iter
    (fun n ->
      let nref = V.as_str (V.get n "ref") in
      let out = ref [] in
      List.iter
        (fun r ->
          if restartcausing r then begin
            let rname = V.as_str (V.get r "name") in
            let from =
              List.map V.as_str (V.items (V.get bycap rname))
            in
            (* A node satisfies its own name AS A REF (§11.1),
               canonically — exactly what `providersof` does at
               runtime, so the load-time graph and the running one
               agree about what an edge is. *)
            let from =
              match Ref.tryref rname with
              | Some a when V.has isref a && not (List.mem a from) ->
                from @ [ a ]
              | _ -> from
            in
            List.iter
              (fun p -> if p <> nref && not (List.mem p !out) then
                          out := !out @ [ p ])
              from
          end)
        (V.items (V.get n "requires"));
      V.set edges nref (V.oflist (List.map V.vstr (List.sort compare !out))))
    (V.items nodes);

  (* Iterative DFS with an explicit stack: twenty ports, and several of
     them have no recursion budget worth relying on. *)
  let white = 0 and grey = 1 and black = 2 in
  let colour = V.vmap () in
  List.iter
    (fun n -> V.set colour (V.as_str (V.get n "ref")) (V.vnum (float_of_int white)))
    (V.items nodes);

  let found = ref None in
  List.iter
    (fun start ->
      if None = !found
         && white = int_of_float (V.as_num (V.get colour start))
      then begin
        let path = ref [ start ] in
        let stack = ref [ (start, ref 0) ] in
        V.set colour start (V.vnum (float_of_int grey));
        while None = !found && [] <> !stack do
          let tref, idx = List.hd !stack in
          let tos = V.get edges tref in
          if !idx >= V.len tos then begin
            V.set colour tref (V.vnum (float_of_int black));
            stack := List.tl !stack;
            path := List.filteri (fun i _ -> i < List.length !path - 1) !path
          end
          else begin
            let next = V.as_str (V.at tos !idx) in
            incr idx;
            let c = int_of_float (V.as_num (V.get colour next)) in
            if c = grey then begin
              (* Report the cycle itself, not the walk that found it. *)
              let started = ref false in
              let cycle =
                List.filter
                  (fun p ->
                    if (not !started) && p = next then started := true;
                    !started)
                  !path
              in
              found := Some (V.oflist (List.map V.vstr (cycle @ [ next ])))
            end
            else if c <> black then begin
              V.set colour next (V.vnum (float_of_int grey));
              path := !path @ [ next ];
              stack := (next, ref 0) :: !stack
            end
          end
        done
      end)
    (V.sortedkeys edges);
  !found

(* Raise on a cycle, naming it. Separate from the detector so the
   detector stays pure and corpus-testable. *)
let checkcycle nodes =
  match dependencycycle nodes with
  | None -> ()
  | Some cycle ->
    Types.fail "plugin_dependency_cycle"
      ("requirements cycle: "
       ^ String.concat " -> " (List.map V.as_str (V.items cycle)))
      ~details:(Types.details1 "cycle" cycle)
