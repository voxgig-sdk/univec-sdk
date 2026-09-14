(* VENDORED: @voxgig/plugin sdk-20260908-1556-0 (ocaml/src/graph.ml) *)
(* Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* Whole-graph resolution (§11.4) — a phase, not a discovery.

   "Activate, and wait in `pending` if you must" is correct and, on its
   own, produces a terrible experience: apply twenty instances against
   a registry missing one thing and you get NINETEEN pending rows and
   no statement of what is actually wrong.

   `resolvegraph` is a PURE FUNCTION of the registry and the intended
   activation set. No callbacks run, no state changes, nothing is
   touched. It answers for the whole graph at once which instances can
   be live, and for each blocked one THE SPECIFIC REQUIREMENT that is
   unmet, and why.

   The failure mode being designed against is a famous one: OSGi's
   resolver is correct and its diagnostics are legendarily unusable. A
   resolver that says "blocked" without saying WHY has moved the
   problem rather than solved it, so `why` is part of the contract. *)

module V = Value

let candidates byref name =
  let out = V.vlist () in
  (* A NODE SATISFIES ITS OWN REF (§11.1), and this is where the graph
     learned it. Considering only declared capabilities made `resolve`
     answer `absent` about a provider sitting right there and live —
     §11.4's whole job is explaining the graph the runtime reconciles,
     and it was explaining a different one. Canonical (§4 rule 5), and
     tolerant, because a capability name need not be a well-formed
     ref. *)
  let asref = if V.is_str name then Ref.tryref (V.as_str name) else None in
  List.iter
    (fun r ->
      let node = V.get byref r in
      let pos = V.get node "pos" in
      let pos = if V.is_num pos then pos else V.vnum 0.0 in
      (* The ref match WINS OUTRIGHT for that node, as at runtime: one
         candidate, not two, for a node both named `b` and providing
         `b` — without the skip the blocked-chain explanation named it
         twice. *)
      if Some r = asref then begin
        let prov = V.vmap () in
        V.set prov "name" name;
        let c = V.vmap () in
        V.set c "ref" (V.get node "ref");
        V.set c "pos" pos;
        V.set c "provides" prov;
        V.push out c
      end
      else
        List.iter
          (fun p ->
            if V.same (V.get p "name") name then begin
              let c = V.vmap () in
              V.set c "ref" (V.get node "ref");
              V.set c "pos" pos;
              V.set c "provides" p;
              V.push out c
            end)
          (V.items (V.get node "provides")))
    (V.sortedkeys byref);
  out

let blockedof node unmet why =
  let out = V.vmap () in
  V.set out "ref" (V.get node "ref");
  V.set out "unmet" unmet;
  V.set out "why" why;
  out

let why1 kind =
  let w = V.vmap () in
  V.set w "kind" (V.vstr kind);
  w

let sortedstrings l = V.oflist (List.map V.vstr (List.sort compare l))

(* The FIRST unmet requirement, with the most specific explanation
   available. Order matters: "no provider at all" and "a provider at
   the wrong version" are different problems and a reader must not have
   to guess which they have. *)
let firstunmet node byref resolved =
  let rec go = function
    | [] -> None
    | req :: rest ->
      if V.truthy (V.get req "optional") then go rest
      else begin
        let name = V.get req "name" in
        let all = candidates byref name in
        if 0 = V.len all then Some (blockedof node name (why1 "absent"))
        else
          let ok = Capability.resolvecapability req all in
          if 0 < V.len ok then begin
            (* A provider exists and matches — but if none of them is
               itself resolved, this node is blocked BEHIND it, and the
               chain is the useful answer rather than "unmet". *)
            let live =
              List.exists
                (fun c -> V.has resolved (V.as_str (V.get c "ref")))
                (V.items ok)
            in
            if live then go rest
            else begin
              let chain =
                List.map (fun c -> V.as_str (V.get c "ref")) (V.items ok)
              in
              let w = why1 "blocked" in
              V.set w "chain" (sortedstrings chain);
              Some (blockedof node name w)
            end
          end
          else begin
            (* Providers exist and none matched. Say which test
               failed. *)
            let range = V.get req "range" in
            let byversion =
              if V.is_null range then None
              else begin
                let found =
                  List.filter_map
                    (fun c ->
                      let prov = V.get c "provides" in
                      let version = V.get prov "version" in
                      if V.is_null version then Some "(none)"
                      else if not (Version.satisfiesq version range) then
                        Some (V.as_str version)
                      else None)
                    (V.items all)
                in
                if [] = found then None
                else begin
                  let w = why1 "version" in
                  V.set w "range" range;
                  V.set w "found" (sortedstrings found);
                  Some (blockedof node name w)
                end
              end
            in
            match byversion with
            | Some b -> Some b
            | None ->
              let m = V.get req "match" in
              let bymatch =
                if V.is_null m then None
                else
                  List.fold_left
                    (fun acc c ->
                      match acc with
                      | Some _ -> acc
                      | None ->
                        let attrs = V.get (V.get c "provides") "attrs" in
                        let attrs =
                          if V.is_null attrs then V.vmap () else attrs
                        in
                        List.fold_left
                          (fun acc2 k ->
                            match acc2 with
                            | Some _ -> acc2
                            | None ->
                              (* The same recursive partial match the
                                 selection applies, so a nested
                                 requirement that FAILED the selection
                                 is also the one the diagnosis names
                                 (§11.4). *)
                              if (not (V.has attrs k))
                                 || not
                                      (Capability.capmatchvalue (V.get m k)
                                         (V.get attrs k))
                              then begin
                                let w = why1 "match" in
                                V.set w "failing" (V.vstr k);
                                V.set w "want" (V.get m k);
                                V.set w "found" (V.get attrs k);
                                Some (blockedof node name w)
                              end
                              else None)
                          None (V.sortedkeys m))
                    None (V.items all)
              in
              (match bymatch with
               | Some b -> Some b
               | None -> Some (blockedof node name (why1 "absent")))
          end
      end
  in
  go (V.items (V.get node "requires"))

let resolvegraph nodes =
  let byref = V.vmap () in
  List.iter (fun n -> V.set byref (V.as_str (V.get n "ref")) n) (V.items nodes);

  let resolved = V.vmap () in

  (* Fixed point: a node resolves when every mandatory requirement is
     met by an ALREADY-RESOLVED provider. Iterating to a fixed point is
     what makes a provider that is itself blocked propagate, rather
     than each node being judged against the raw registry. *)
  let moved = ref true in
  while !moved do
    moved := false;
    List.iter
      (fun n ->
        let r = V.as_str (V.get n "ref") in
        if (not (V.has resolved r)) && None = firstunmet n byref resolved then begin
          V.set resolved r (V.vbool true);
          moved := true
        end)
      (V.items nodes)
  done;

  let blocked = V.vmap () in
  List.iter
    (fun n ->
      let r = V.as_str (V.get n "ref") in
      if not (V.has resolved r) then
        match firstunmet n byref resolved with
        | Some why -> V.set blocked r why
        | None -> ())
    (V.items nodes);

  let out = V.vmap () in
  V.set out "resolved" (V.oflist (List.map V.vstr (V.sortedkeys resolved)));
  V.set out "blocked"
    (V.oflist (List.map (V.get blocked) (V.sortedkeys blocked)));
  out
