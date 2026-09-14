(* VENDORED: @voxgig/plugin sdk-20260908-1556-0 (ocaml/src/capability.ml) *)
(* Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* Capabilities (§11.1).

   A DEPENDENCY IS ON A CAPABILITY, NOT ON A REF — because it is a
   dependency on something that can do the job, and which instance is
   doing it is exactly the configuration detail a plugin must not care
   about. (§11.1 makes one narrow exception for a ref, and `host.ml`
   implements it; the ranking here is capabilities only.)

   But A BINDING IS TO AN INSTANCE, not to a capability, which is what
   decides behaviour when the bound provider leaves while another match
   remains. *)

module V = Value

(* PARTIAL MATCH, RECURSING INTO MAPS (§11.1). THIS FUNCTION IS WHAT
   "EVERY LEAF" MEANS, and an earlier draft of the canonical did not
   have it: the check was a scalar compare, which for any compound
   value is reference identity in JavaScript. A requirement and a
   capability are declared in different places and are never the same
   object, so `match: {limits: {max: 5}}` could not be satisfied by ANY
   provider — including one declaring exactly that. Invisible while
   every corpus entry is scalar, which is why the go port found it and
   P2 did not.

   A LIST IS COMPARED LEAF-WISE AT THE SAME LENGTH, not as a subset —
   "the first two of your three regions" is not something `match` can
   say. *)
let rec capmatchvalue want got =
  if V.is_map want then
    V.is_map got
    && List.for_all
         (fun k -> V.has got k && capmatchvalue (V.get want k) (V.get got k))
         (V.keys want)
  else if V.is_list want then
    V.is_list got && V.len want = V.len got
    && List.for_all2 capmatchvalue (V.items want) (V.items got)
  else V.same want got

let capmatches req prov =
  if not (V.same (V.get req "name") (V.get prov "name")) then false
  else
    let range = V.get req "range" in
    let versionok =
      if V.is_null range then true
      else
        let version = V.get prov "version" in
        (not (V.is_null version)) && Version.satisfiesq version range
    in
    if not versionok then false
    else
      (* `match` is checked against the provider's `attrs`, key by key.
         A key the provider does not carry is a MISS, not a pass: a
         requirement asking for `transactional: true` must not be
         satisfied by a provider that never said. *)
      let m = V.get req "match" in
      if V.is_null m then true
      else
        let attrs = V.get prov "attrs" in
        let attrs = if V.is_null attrs then V.vmap () else attrs in
        List.for_all
          (fun k -> V.has attrs k && capmatchvalue (V.get m k) (V.get attrs k))
          (V.keys m)

(* The rank, as a comparison over two candidates. Ordering is a TOTAL
   rank on purpose: without one, "any provider satisfies" is true of
   the GRAPH and useless to the PLUGIN — two ports could bind different
   `store` instances, both resolve green, and behave differently, which
   is precisely the divergence a shared corpus exists to catch. *)
let rank a b =
  let ap = V.get a "provides" and bp = V.get b "provides" in
  let av = V.get ap "version" and bv = V.get bp "version" in
  let ahas = not (V.is_null av) and bhas = not (V.is_null bv) in
  if ahas <> bhas then if ahas then -1 else 1  (* a version beats none *)
  else
    let byversion =
      if ahas && bhas then
        (* HIGHEST version first, so the comparison is reversed. *)
        try Version.vercmp (Version.parseversion bv) (Version.parseversion av)
        with Types.Plugin_error _ -> 0
      else 0
    in
    if 0 <> byversion then byversion
    else
      let pri p =
        let v = V.get p "priority" in
        if V.is_num v then V.as_num v else 0.0
      in
      let apri = pri ap and bpri = pri bp in
      (* LOWEST priority first. *)
      if apri <> bpri then if apri < bpri then -1 else 1
      else
        let apos = V.as_num (V.get a "pos") and bpos = V.as_num (V.get b "pos") in
        if apos <> bpos then if apos < bpos then -1 else 1 else 0

let resolvecapability req candidates =
  let hits = List.filter (fun c -> capmatches req (V.get c "provides"))
               (V.items candidates) in
  (* `List.stable_sort` and `rank` is a TOTAL order (it falls through
     to `pos`, which is unique), so stability is not relied on. An
     earlier reading that stopped at `priority` would have left ties to
     the sort's discretion, which is exactly the per-port divergence
     the ranking exists to remove. *)
  V.oflist (List.stable_sort rank hits)
