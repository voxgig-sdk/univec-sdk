(* VENDORED: @voxgig/plugin sdk-20260908-1556-0 (ocaml/src/host.ml) *)
(* Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* The host: the lifecycle state machine (§5), extension points (§6),
   and resource capture (§8).

   TWO RULES SHAPE EVERY FUNCTION HERE.

   Transitions are SEQUENTIAL (§5.2). One at a time, in call order,
   never interleaved; a transition triggered from inside a lifecycle
   callback is `plugin_reentrant`. A hard rule, because it is the only
   way the semantics can be identical in Go, in Ruby and in
   single-threaded JavaScript — and in OCaml, which has no event loop
   to hide behind.

   Reconciliation is EAGER (§18's portability budget). A transition
   settles by running the state machine to a fixed point, not by
   suspending on a promise. *)

module V = Value
open Defs

(* ------------------------------------------------------------------ *)
(* construction and registry helpers                                   *)
(* ------------------------------------------------------------------ *)

let makehost (o : hostoptions) =
  {
    hcatalog = (match o.ocatalog with Some c -> c | None -> Catalog.makecatalog ());
    reserved = o.oreserved;
    keys = o.okeys;
    defaults = o.odefaults;
    profile = o.oprofile;
    points = (if V.is_map o.opoints then o.opoints else V.vmap ());
    bases = o.obases;
    dependency = (if "" = o.odependency then "restart" else o.odependency);
    coordinated = false;
    instances = [];
    hlog = V.vlist ();
    events = V.vlist ();
    seqn = 0.0;
    openc = 0.0;
    intransition = false;
    phase = "";
  }

let define h def = Catalog.add h.hcatalog def

let find h r = List.find_opt (fun e -> e.iref = r) h.instances

(* Every instance ref, SORTED — the deterministic walk §4 rule 4
   requires in a language whose containers have no inherent order. *)
let sortedrefs h = List.sort compare (List.map (fun e -> e.iref) h.instances)

(* ------------------------------------------------------------------ *)
(* observation                                                         *)
(* ------------------------------------------------------------------ *)

let list h =
  let out = V.vmap () in
  List.iter
    (fun r ->
      match find h r with Some e -> V.set out r (V.vstr e.status) | None -> ())
    (sortedrefs h);
  out

(* The VALIDATING canonicalizer, not the forgiving one: a lookup with a
   malformed ref is `plugin_bad_name`, not a miss
   (`declare/lookup#malformed`). Rust and swift both wrote this with
   `canon` and failed that entry. *)
let instance h r = find h (Ref.canonrefs r)

let observable h result =
  let out = V.vmap () in
  V.set out "status" (list h);
  V.set out "open" (V.vnum h.openc);
  V.set out "log" (V.oflist (V.items h.hlog));
  V.set out "result" (match result with Some v -> v | None -> V.vnull);
  out

let trace h = h.events
let instname e = Ref.refname e.iref

let insttag e =
  match String.index_opt e.iref '$' with
  | None -> ""
  | Some c -> String.sub e.iref (c + 1) (String.length e.iref - c - 1)

(* ------------------------------------------------------------------ *)
(* guards                                                              *)
(* ------------------------------------------------------------------ *)

let guard h =
  if h.intransition then
    Types.fail "plugin_reentrant"
      "transition attempted from inside a lifecycle callback"

let need h r =
  let r = Ref.canonrefs r in
  match find h r with
  | Some e -> e
  | None ->
    Types.fail "plugin_not_loaded"
      ("no such instance: " ^ r)
      ~details:(Types.details1 "ref" (V.vstr r))

let checkreserved h r =
  if V.is_list h.reserved && 0 < V.len h.reserved then begin
    let name = Ref.refname r in
    if List.exists (fun x -> V.is_str x && V.as_str x = name)
         (V.items h.reserved)
    then
      Types.fail "plugin_ref_reserved"
        ("ref is reserved by the host: " ^ r)
        ~details:(Types.details1 "ref" (V.vstr r))
  end

(* ------------------------------------------------------------------ *)
(* scope                                                               *)
(* ------------------------------------------------------------------ *)

(* A selection belongs to ONE activation (§11.4). Leaving `live` by any
   door drops it, so the next activation ranks afresh — keeping it
   would make a consumer prefer a provider it never actually ran
   against.

   Answers the errors the scope raised. §8.3: "A failing release does
   not stop the rest. Every entry runs, in reverse order, whatever any
   of them does; the errors are collected and raised as one
   `plugin_release_failed`." *)
let unwind h e =
  e.selected <- V.vmap ();
  let errors = V.vlist () in
  List.iter
    (fun s ->
      if not s.done_ then begin
        s.done_ <- true;
        if s.counts then h.openc <- h.openc -. 1.0;
        match s.sfn with
        | None -> ()
        | Some f -> (
          try f ()
          with Types.Plugin_error err -> V.push errors (V.vstr err.Types.message))
      end)
    (List.rev e.scope);
  e.scope <- [];
  errors

(* §8.3: "A failed release ends the instance in `failed`, exactly as a
   failed callback does (§5.2) — a release that raised may have leaked,
   and an instance that may be holding resources it cannot account for
   must not be reactivated." *)
let releasecheck e errors =
  if 0 < V.len errors then begin
    e.status <- "failed";
    let d = V.vmap () in
    V.set d "ref" (V.vstr e.iref);
    V.set d "cause" errors;
    Types.fail "plugin_release_failed"
      ("release failed for " ^ e.iref ^ ": "
       ^ String.concat "; " (List.map V.as_str (V.items errors)))
      ~details:d
  end

(* ------------------------------------------------------------------ *)
(* the instance api                                                    *)
(* ------------------------------------------------------------------ *)

let acquire e =
  (* §8.1: resources are "acquired during `activate` — the scope's
     actual job". *)
  if "activate" <> e.owner.phase then
    Types.fail "plugin_release_scope" "acquire called outside activate";
  let s = { sfn = None; done_ = false; counts = true } in
  e.scope <- e.scope @ [ s ];
  e.owner.openc <- e.owner.openc +. 1.0;
  s

(* Hand a resource back before teardown. Idempotent, and the scope
   keeps the entry: unwinding it again must be a no-op, or releasing
   early would make teardown wrong. *)
let giveback e s =
  if not s.done_ then begin
    s.done_ <- true;
    if s.counts then e.owner.openc <- e.owner.openc -. 1.0
  end

let release e fn =
  (* §8.3: "`inst.release` outside `activate` is
     `plugin_release_scope`". Being in a transition is true in `define`
     too, and a scope entry registered there is never unwound —
     `unload` on a merely `loaded` instance does not unwind, because a
     loaded instance is not supposed to hold anything. *)
  if "activate" <> e.owner.phase then
    Types.fail "plugin_release_scope" "release called outside activate";
  (* SYMMETRIC WITH `acquire`, and it has to be: `open` counts the
     resources CURRENTLY HELD, so an entry that is registered and then
     unwound must leave the count where it found it. Incrementing on
     registration and never decrementing made every `release` a
     permanent leak in the counter. *)
  e.scope <- e.scope @ [ { sfn = fn; done_ = false; counts = true } ];
  e.owner.openc <- e.owner.openc +. 1.0

let bind e point hook chain band =
  let h = e.owner in
  (* §12's `plugin_bind_scope`: "binding declared outside `define`".
     §8.1 puts binding declaration in `define` and insertion at a
     SUCCESSFUL activate, and the guard was the half that never got
     written — so a binding added from `activate` went live without
     being part of the loaded definition, and a deactivate/activate
     cycle appended it again. The code was in the table before anything
     raised it. *)
  if "define" <> h.phase then begin
    let d = V.vmap () in
    V.set d "ref" (V.vstr e.iref);
    V.set d "point" (V.vstr point);
    Types.fail "plugin_bind_scope" ("bind called outside define: " ^ point)
      ~details:d
  end;
  if not (V.has h.points point) then
    Types.fail "plugin_point_unknown"
      ("no such point: " ^ point)
      ~details:(Types.details1 "point" (V.vstr point));
  let b =
    { Point.bref = e.iref; bpoint = point;
      band = (if V.is_num band then V.as_num band else 0.0);
      bhook = hook; bchain = chain }
  in
  e.bindings <- e.bindings @ [ b ]

let bindhook e point hook band = bind e point (Some hook) None band
let bindchain e point chain band = bind e point None (Some chain) band
let exportvalue e key value = V.set e.exports key value
let provides e p = V.push e.provides p

(* ------------------------------------------------------------------ *)
(* running a callback                                                  *)
(* ------------------------------------------------------------------ *)

let run h e at =
  let fn = Catalog.callback e.idef at in

  V.push h.hlog (V.vstr (e.iref ^ ":" ^ at));
  let ev = V.vmap () in
  V.set ev "ref" (V.vstr e.iref);
  V.set ev "event" (V.vstr at);
  V.set ev "seq" (V.vnum e.seq);
  V.set ev "status" (V.vstr e.status);
  V.push h.events ev;

  match fn with
  | None -> ()
  | Some f -> (
    h.intransition <- true;
    h.phase <- at;
    let finish () =
      h.intransition <- false;
      h.phase <- ""
    in
    match f e with
    | () -> finish ()
    | exception Types.Plugin_error err ->
      finish ();
      (* §12: `plugin_define_failed` and its three siblings are "a
         callback raised; wraps the cause". AN ERROR THAT ALREADY
         CARRIES A CODE KEEPS IT — the code is the error's identity,
         and a plugin that raised `store_unreachable` must not have it
         rewritten. Only a code-less error is wrapped, which is the
         ordinary case for a callback that let a library error
         escape. *)
      if "" <> err.Types.code && "plugin_bare" <> err.Types.code then
        raise (Types.Plugin_error err);
      let d = V.vmap () in
      V.set d "ref" (V.vstr e.iref);
      V.set d "cause" (V.vstr err.Types.text);
      Types.fail
        ("plugin_" ^ at ^ "_failed")
        (e.iref ^ " raised in " ^ at ^ ": " ^ err.Types.text)
        ~details:d)

(* ------------------------------------------------------------------ *)
(* requirements and providers                                          *)
(* ------------------------------------------------------------------ *)

let providersof h req =
  let cands = V.vlist () in
  (* ASK WHETHER THE NAME IS A REF, do not assume it. A requirement
     name is a CAPABILITY name first (§11.1) and capability names are
     free-form, so `2fa` and `my cap` are legal ones that no ref could
     be called — and `canonref` RAISES on those, which made a perfectly
     legal document kill the host right here. *)
  let rname = V.get req "name" in
  let asref = if V.is_str rname then Ref.tryref (V.as_str rname) else None in
  List.iter
    (fun r ->
      match find h r with
      | None -> ()
      | Some t ->
        if "live" = t.status then
          (* A ref satisfies directly. *)
          if Some r = asref then begin
            let prov = V.vmap () in
            V.set prov "name" rname;
            let c = V.vmap () in
            V.set c "ref" (V.vstr r);
            V.set c "pos" (V.vnum t.pos);
            V.set c "provides" prov;
            V.push cands c
          end
          else
            List.iter
              (fun p ->
                if V.same (V.get p "name") rname then begin
                  let c = V.vmap () in
                  V.set c "ref" (V.vstr r);
                  V.set c "pos" (V.vnum t.pos);
                  V.set c "provides" p;
                  V.push cands c
                end)
              (V.items t.provides))
    (sortedrefs h);
  Capability.resolvecapability req cands

let unmetof h e =
  V.oflist
    (List.filter_map
       (fun r ->
         if Depend.gatesactivation r && 0 = V.len (providersof h r) then
           Some (V.get r "name")
         else None)
       (V.items (Depend.requirements e.options)))

(* §11.4's always-reluctant selection, and the ONE place a provider is
   chosen for a live instance. "A satisfied requirement is not re-bound
   while it stays satisfied" is a statement about a REMEMBERED choice.

   `remember` is false for the questions asked ABOUT an instance rather
   than BY it — introspection must not create a binding. *)
let chosen h e req remember =
  let cands = providersof h req in
  if 0 = V.len cands then None
  else begin
    let name = V.as_str (V.get req "name") in
    let heldv = V.get e.selected name in
    let kept =
      if V.is_str heldv
         && List.exists
              (fun c -> V.as_str (V.get c "ref") = V.as_str heldv)
              (V.items cands)
      then Some (V.as_str heldv)
      else None
    in
    match kept with
    | Some r -> Some r
    | None ->
      let first = V.as_str (V.get (V.at cands 0) "ref") in
      if remember then V.set e.selected name (V.vstr first);
      Some first
  end

(* The instance currently SELECTED for each of this one's
   restart-causing requirements. A BINDING IS TO AN INSTANCE, not to a
   capability (§11.1): the selected one going away restarts a `static`
   consumer even though a survivor is available. *)
let boundproviders h e =
  let out = ref [] in
  List.iter
    (fun r ->
      if Depend.restartsonloss r then
        match chosen h e r false with
        | Some p when not (List.mem p !out) -> out := !out @ [ p ]
        | _ -> ())
    (V.items (Depend.requirements e.options));
  !out

let consumersof h r =
  List.filter
    (fun c ->
      c <> r
      &&
      match find h c with
      | Some ci -> "live" = ci.status && List.mem r (boundproviders h ci)
      | None -> false)
    (sortedrefs h)

(* §11.3's `hold` asks a DIFFERENT question from the cascade.

   The cascade wants the edges that RESTART — mandatory-static and
   optional-static. `hold` says "deactivating a REQUIRED instance is
   `plugin_dependency_held`", and `required` is CARDINALITY:
   `gatesactivation`, not `restartsonloss`. The two sets differ in both
   directions and each difference was a real bug. *)
let holdersof h r =
  List.filter
    (fun c ->
      c <> r
      &&
      match find h c with
      | Some ci ->
        "live" = ci.status
        && List.exists
             (fun req ->
               Depend.gatesactivation req && Some r = chosen h ci req false)
             (V.items (Depend.requirements ci.options))
      | None -> false)
    (sortedrefs h)

(* The hold check is A GUARD ON AD-HOC DEACTIVATION, NOT ON COORDINATED
   TEARDOWN. In a bulk operation that is removing the holders too, it
   is suspended — otherwise `close()` under `hold` would raise on the
   first provider it reached whenever a document happened to list a
   consumer after it, which is the policy refusing the one teardown it
   has no reason to object to. *)
let held h e =
  if "hold" = h.dependency && not h.coordinated then begin
    let holders = holdersof h e.iref in
    if [] <> holders then begin
      let d = V.vmap () in
      V.set d "ref" (V.vstr e.iref);
      V.set d "holders" (V.oflist (List.map V.vstr holders));
      Types.fail "plugin_dependency_held"
        ("instance is required by live consumers: " ^ e.iref)
        ~details:d
    end
  end

(* The requirement graph as plain data, for the pure detector. *)
let graphnodes h =
  V.oflist
    (List.filter_map
       (fun r ->
         match find h r with
         | None -> None
         | Some e ->
           let node = V.vmap () in
           V.set node "ref" (V.vstr r);
           V.set node "provides"
             (V.oflist (List.map (fun p -> V.get p "name") (V.items e.provides)));
           V.set node "requires" (Depend.requirements e.options);
           Some node)
       (sortedrefs h))

(* ------------------------------------------------------------------ *)
(* ordering and points                                                 *)
(* ------------------------------------------------------------------ *)

let order h point =
  (* Sorted by declaration SEQUENCE, which is what makes the §7 sort's
     fall-through deterministic in a language whose containers have no
     insertion order. §7 breaks ties by `pos`; two instances CAN share
     one — `declare` defaults `pos` to the registry size, so an unload
     followed by a fresh declare reuses a surviving instance's — and
     past that the canonical was falling through to map order. `seq` is
     that order, made explicit. Found by review of the go port. *)
  let live =
    List.stable_sort
      (fun a b -> compare a.seq b.seq)
      (List.filter (fun e -> "live" = e.status) h.instances)
  in
  let bindings =
    V.oflist
      (List.map
         (fun e ->
           let b = V.vmap () in
           V.set b "ref" (V.vstr e.iref);
           V.set b "pos" (V.vnum e.pos);
           if not (V.is_null e.order) then V.set b "order" e.order;
           b)
         live)
  in
  let spec = if "" = point then V.vnull else V.get h.points point in
  Order.resolveorder bindings (if V.is_map spec then V.get spec "pin" else V.vnull)

let positionof h r point =
  let ranked = order h point in
  let r = Ref.canonrefs r in
  let index = ref (-1.0) in
  List.iteri
    (fun i v -> if -1.0 = !index && V.as_str v = r then index := float_of_int i)
    (V.items ranked);
  let out = V.vmap () in
  V.set out "index" (V.vnum !index);
  V.set out "count" (V.vnum (float_of_int (V.len ranked)));
  (* §6.2 composes b1(b2(b3(base))) with the FIRST binding OUTERMOST,
     so these are not index 0 and count-1 the other way round. Getting
     this backwards is the exact error the positional pin vocabulary
     exists to prevent. *)
  V.set out "outermost" (V.vbool (0.0 = !index));
  V.set out "innermost"
    (V.vbool (!index = float_of_int (V.len ranked) -. 1.0));
  out

let position e point = positionof e.owner e.iref point

(* Live bindings on a point, in resolved order. Recomputed on any
   change to the live set (§7) rather than cached at startup — the bug
   a host discovers only when something deactivates in production. *)
let boundon h point =
  List.concat_map
    (fun rv ->
      match find h (V.as_str rv) with
      | None -> []
      | Some e ->
        (* The band is the INSTANCE's ordering block (§7), stamped by
           the host. A plugin passing its own would be ranking itself
           above the order its document declared. *)
        let band = V.get e.order "band" in
        let bandv = if V.is_num band then V.as_num band else 0.0 in
        List.filter_map
          (fun b ->
            if b.Point.bpoint = point then Some { b with Point.band = bandv }
            else None)
          e.bindings)
    (V.items (order h point))

let pointspec h point =
  if not (V.has h.points point) then
    Types.fail "plugin_point_unknown"
      ("no such point: " ^ point)
      ~details:(Types.details1 "point" (V.vstr point));
  let spec = V.get h.points point in
  if V.is_map spec then spec else V.vmap ()

let checkkind spec point want =
  let kind = V.get spec "kind" in
  let given = V.is_str kind in
  let ok = if given then V.as_str kind = want else "hook" = want in
  if not ok then begin
    let d = V.vmap () in
    V.set d "point" (V.vstr point);
    V.set d "kind" (if given then kind else V.vnull);
    Types.fail "plugin_point_kind" ("point is not a " ^ want ^ ": " ^ point)
      ~details:d
  end

let emit h point arg =
  let spec = pointspec h point in
  checkkind spec point "hook";
  let bindings = boundon h point in
  let mode = V.get spec "mode" in
  let m = if V.is_str mode then V.as_str mode else "emit" in
  let out, errors = Point.pointemit bindings m arg in
  if "emit" = m then None else if "bail" = m then out else Some errors

let call h point arg =
  let spec = pointspec h point in
  checkkind spec point "chain";
  let bindings = boundon h point in
  (* The host owns the base and a plugin cannot replace it (§6.2). One
     that wants to SUBSTITUTE rather than wrap binds innermost and
     simply does not call `next`. *)
  Point.pointcall bindings (List.assoc_opt point h.bases) arg

let provider h point arg =
  let spec = pointspec h point in
  checkkind spec point "provider";
  let bindings = boundon h point in
  let winner, _ = Point.pointprovider bindings (V.truthy (V.get spec "exclusive")) in
  match winner with
  | None -> Some (V.get spec "default")
  | Some b -> Point.callhook b arg

let shadowed h point =
  if not (V.has h.points point) then V.vlist ()
  else begin
    let spec = V.get h.points point in
    let bindings = boundon h point in
    let _, sh =
      Point.pointprovider bindings
        (V.is_map spec && V.truthy (V.get spec "exclusive"))
    in
    sh
  end

let exports h spec =
  let all = V.vlist () in
  List.iter
    (fun r ->
      match find h r with
      | None -> ()
      | Some e ->
        (* Exports of a `loaded` (not live) instance are VISIBLE
           (§11). *)
        if "declared" <> e.status && "failed" <> e.status then
          List.iter
            (fun k ->
              let ex = V.vmap () in
              V.set ex "ref" (V.vstr r);
              V.set ex "key" (V.vstr k);
              V.set ex "value" (V.get e.exports k);
              V.push all ex)
            (V.keys e.exports))
    (sortedrefs h);
  Export.resolveexport (V.vstr spec) all

let capability h name =
  let cands = V.vlist () in
  List.iter
    (fun r ->
      match find h r with
      | None -> ()
      | Some e ->
        if "live" = e.status then
          List.iter
            (fun p ->
              if V.is_str (V.get p "name") && V.as_str (V.get p "name") = name
              then begin
                let c = V.vmap () in
                V.set c "ref" (V.vstr r);
                V.set c "pos" (V.vnum e.pos);
                V.set c "provides" p;
                V.push cands c
              end)
            (V.items e.provides))
    (sortedrefs h);
  let req = V.vmap () in
  V.set req "name" (V.vstr name);
  V.oflist
    (List.map (fun c -> V.get c "ref")
       (V.items (Capability.resolvecapability req cands)))

(* ------------------------------------------------------------------ *)
(* the state machine                                                   *)
(* ------------------------------------------------------------------ *)

(* AUTO-TAGGING IS EXPLICIT (§4 rule 3): the LOWEST UNUSED POSITIVE
   INTEGER tag. It needs a host because it must know what is already
   declared, which is why it cannot live in the pure `ref` section. *)
let autotag h name =
  let rec go n =
    let cand = Ref.formatref (V.vstr name) (V.vstr (string_of_int n)) in
    if None = find h cand then cand else go (n + 1)
  in
  go 1

let declare h r spec =
  let r =
    if "?" = spec.stag then autotag h (Ref.refname (Ref.canonrefs r))
    else Ref.canonrefs r
  in
  if not spec.shostowned then checkreserved h r;

  let defname = if "" = spec.sdefinition then Ref.refname r else spec.sdefinition in
  let def =
    match Catalog.get h.hcatalog defname with
    | Some d -> d
    | None ->
      Types.fail "plugin_unknown_definition"
        ("not in catalog: " ^ defname)
        ~details:(Types.details1 "name" (V.vstr defname))
  in

  match find h r with
  | Some existing ->
    (* §4 rule 1: a pair addresses at most one instance. Re-declaring
       the SAME definition is the idempotent case; a different one is a
       duplicate, not a silent overwrite (seneca) and not an
       impossibility (sdkgen). *)
    if existing.idef.dname <> def.dname then
      Types.fail "plugin_ref_duplicate"
        ("instance already declared: " ^ r)
        ~details:(Types.details1 "ref" (V.vstr r));
    existing
  | None ->
    let e =
      {
        iref = r;
        idef = def;
        status = "declared";
        pos =
          (match spec.spos with
           | Some p -> p
           | None -> float_of_int (List.length h.instances));
        seq = h.seqn;
        (* NO OPTIONS ADOPTED HERE. `apply` resolves options and hands
           the map over; adopting the caller's map made target and
           source THE SAME MAP in the refill that follows, which
           cleared its own source and left a first-time instance with
           no options at all. *)
        options =
          (match spec.soptions with
           | Some o when V.is_map o -> o
           | _ -> V.vmap ());
        istate = V.vmap ();
        order = spec.sorder;
        selected = V.vmap ();
        barred = false;
        unmet = V.vlist ();
        scope = [];
        bindings = [];
        inner = None;
        exports = V.vmap ();
        provides = V.vlist ();
        owner = h;
      }
    in
    h.seqn <- h.seqn +. 1.0;
    h.instances <- h.instances @ [ e ];
    e

let load h r spec =
  guard h;
  let e = declare h r spec in
  if "declared" <> e.status then e   (* idempotent *)
  else begin
    (* PRESENT AND NOT NULL, not merely present. Every driver builds
       its command spec with all four keys and a null for each absent
       one, so a presence test reads an omitted `options` as an
       authored empty and wipes the real ones. *)
    (match spec.soptions with
     | Some o when V.is_map o -> e.options <- o
     | _ -> ());

    (try run h e "define"
     with err -> e.status <- "failed"; raise err);
    e.status <- "loaded";

    (* AT LOAD, and before anything runs: a cycle through
       restart-causing requirements does not settle, and the only safe
       time to report a non-terminating reconcile is before it starts
       (§11.3). `provides` is populated by `define`, which has just
       run, so this is the first moment the graph is complete. *)
    (try Depend.checkcycle (graphnodes h)
     with err -> e.status <- "failed"; raise err);
    e
  end

(* CONSUMERS GO DOWN FIRST, NOT AFTERWARDS (§11.3).

   The cascade is part of the provider's own deactivation and runs
   BEFORE the provider's `deactivate` callback and scope unwind, so a
   consumer's teardown can still call the thing it depends on —
   flushing a buffer to the store it is about to lose is exactly what a
   `deactivate` callback is for. *)
let rec cascade h provider seen =
  if not (V.has seen provider.iref) then begin
    V.set seen provider.iref (V.vbool true);
    List.iter
      (fun cref ->
        match find h cref with
        | Some c when "live" = c.status ->
          cascade h c seen;                    (* deepest-first *)
          let bad =
            try run h c "deactivate"; false with Types.Plugin_error _ -> true
          in
          let errors = unwind h c in
          if bad || 0 < V.len errors then
            (* §5.2: ANY failure during a transition lands the instance
               in `failed`, and a cascaded consumer is not an
               exception. Marking it `pending` instead handed it
               straight back to `reconcile`, which would activate it
               again the moment the provider returned — the one thing
               `failed` exists to stop. *)
            c.status <- "failed"
          else begin
            c.status <- "pending";
            c.unmet <- unmetof h c
          end
        | _ -> ())
      (consumersof h provider.iref)
  end

let rec activate h r =
  guard h;
  let e = need h r in
  if "live" = e.status then e                  (* no-op returning success *)
  else begin
    if "failed" = e.status then
      Types.fail "plugin_bad_state"
        ("instance has failed: " ^ e.iref)
        ~details:(Types.details1 "ref" (V.vstr e.iref));
    (* §9.6: `active: false` bars the instance from running, and the
       bar is on the INSTANCE rather than on the apply that set it.
       `ready` reaches this through `activate`, which is why one guard
       covers both verbs the design names. *)
    if e.barred then
      Types.fail "plugin_inactive"
        ("instance is barred by active: false: " ^ e.iref)
        ~details:(Types.details1 "ref" (V.vstr e.iref));
    if "declared" = e.status then ignore (load h e.iref nospec);

    (* A declared requirement that is not live means `pending`:
       activation is a STANDING REQUEST, not a one-shot event. *)
    let unmet = unmetof h e in
    if 0 < V.len unmet then begin
      e.unmet <- unmet;
      e.status <- "pending";
      e
    end
    else begin
      (try run h e "activate"
       with err ->
         (* Unwind whatever the partial activation captured, in
            reverse. *)
         ignore (unwind h e);
         e.status <- "failed";
         raise err);

      (* §11.4: THE SELECTION IS MADE HERE, once, and remembered. Every
         later question — the cascade, `hold`, `unmet` — reads it back
         rather than re-ranking, which is what "always-reluctant"
         means. *)
      List.iter
        (fun req -> ignore (chosen h e req true))
        (V.items (Depend.requirements e.options));
      e.status <- "live";
      reconcile h;
      e
    end
  end

and deactivate h r =
  guard h;
  let e = need h r in
  if "loaded" = e.status || "declared" = e.status then e
  else begin
    (* §5.2: `unload` is THE ONLY TRANSITION OUT OF `failed`. Falling
       through here ran the definition's `deactivate` on an instance
       that never completed activation and, if that callback happened
       to succeed, returned it to `loaded` — from where it could be
       activated again, which is precisely what `failed` exists to
       prevent. *)
    if "failed" = e.status then
      Types.fail "plugin_bad_state"
        ("instance has failed: " ^ e.iref)
        ~details:(Types.details1 "ref" (V.vstr e.iref));

    if "pending" = e.status then begin
      (* DEACTIVATING A PENDING INSTANCE RUNS NO CALLBACK (§5.2). It
         never reached activate, so it holds no scope and no live
         bindings; running the definition's deactivate there would be
         teardown without matching setup. It cannot fail. *)
      e.status <- "loaded";
      e.unmet <- V.vlist ();
      e
    end
    else begin
      held h e;
      cascade h e (V.vmap ());
      (try run h e "deactivate"
       with err ->
         ignore (unwind h e);
         e.status <- "failed";
         raise err);
      releasecheck e (unwind h e);
      e.status <- "loaded";
      reconcile h;
      e
    end
  end

and unload h r =
  guard h;
  let e = need h r in
  if "live" = e.status || "pending" = e.status then begin
    if "live" = e.status then begin
      held h e;
      cascade h e (V.vmap ());
      (try run h e "deactivate"
       with err ->
         (* §5.2: ANY failure during a transition lands the instance in
            `failed`, with the scope STILL FULLY UNWOUND. An earlier
            draft let the raise propagate straight out of `unload`,
            which left the instance `live` and its scope untouched —
            reporting a failure while leaking exactly the resources the
            failure was about. *)
         ignore (unwind h e);
         e.status <- "failed";
         raise err);
      releasecheck e (unwind h e)
    end;
    e.status <- "loaded"
  end;
  let drop () = h.instances <- List.filter (fun x -> x != e) h.instances in
  if "loaded" = e.status || "failed" = e.status then
    (try run h e "close" with err -> drop (); raise err);
  drop ()

(* EAGER reconciliation: run to a fixed point rather than scheduling.

   Two directions, and both are the reason `pending` exists. Activation
   is a STANDING REQUEST, not a one-shot event: a pending instance
   whose requirement arrives activates without being asked again, and a
   LIVE instance whose requirement is lost goes back to pending —
   recursively, through its own consumers. *)
and reconcile h =
  let moved = ref true in
  let rounds = ref 0 in
  while !moved && !rounds <= 1000 do
    moved := false;
    incr rounds;

    (* Losses first, so a cascade settles in one pass rather than
       alternating with re-activations. *)
    List.iter
      (fun r ->
        match find h r with
        | Some e when "live" = e.status ->
          let lost =
            List.filter
              (fun q ->
                Depend.gatesactivation q && 0 = V.len (providersof h q))
              (V.items (Depend.requirements e.options))
          in
          (* POLICY IS PER REQUIREMENT, not per instance (§11.3): only
             the definition that has the requirement knows what it can
             cope with, and one instance may hold both a `static` and a
             `dynamic` one. A `dynamic` requirement whose provider is
             gone leaves the consumer LIVE and notified. *)
          if [] <> lost && List.exists Depend.restartsonloss lost then begin
            let bad =
              try run h e "deactivate"; false with Types.Plugin_error _ -> true
            in
            let errors = unwind h e in
            if bad || 0 < V.len errors then e.status <- "failed"
            else begin
              e.status <- "pending";
              e.unmet <- unmetof h e
            end;
            moved := true
          end
        | _ -> ())
      (sortedrefs h);

    List.iter
      (fun r ->
        match find h r with
        | Some e when "pending" = e.status && 0 = V.len (unmetof h e) -> (
          try
            run h e "activate";
            List.iter
              (fun req -> ignore (chosen h e req true))
              (V.items (Depend.requirements e.options));
            e.status <- "live";
            e.unmet <- V.vlist ();
            moved := true
          with Types.Plugin_error _ ->
            ignore (unwind h e);
            e.status <- "failed";
            moved := true)
        | _ -> ())
      (sortedrefs h)
  done

let ready h r =
  (* Runs the whole forward path in one call (§5.1). §15.2's verb list
     omits this; §5.1 defines it and §15.3's `declare` row requires the
     corpus to pin it, so the list was incomplete rather than excluding
     it (DOCS.md §4.2). *)
  guard h;
  let r = Ref.canonrefs r in
  if None = find h r then ignore (declare h r nospec);
  (match find h r with
   | Some e when "declared" = e.status -> ignore (load h r nospec)
   | _ -> ());
  activate h r

let close h =
  (* A bulk teardown removing the holders too, so `hold` is suspended
     for exactly those holders (§11.3) — while the consumers-first
     cascade still runs, which is the half that matters. *)
  h.coordinated <- true;
  (* Reverse load order: highest `pos` first, ref-descending for a tie,
     so a consumer declared after its provider goes down first. *)
  let refs =
    List.map (fun e -> e.iref)
      (List.stable_sort
         (fun a b ->
           if a.pos <> b.pos then compare b.pos a.pos else compare b.iref a.iref)
         h.instances)
  in
  (* A COORDINATED FLAG THAT SURVIVES A RAISE IS A DISABLED GUARD. The
canonical wraps the teardown in [try/finally[; here an unload that
raises would skip the reset and leave the host permanently
[coordinated[, so a caller that catches the error and carries on under
[dependency: "hold"[ gets ad-hoc deactivation with the holder check
silently off. *)
  (match List.iter (fun r -> if None <> find h r then unload h r) refs with
   | () -> h.coordinated <- false
   | exception err -> h.coordinated <- false; raise err)

(* AN INSTANCE MAY ITSELF BE A HOST (§6.5), and THE OUTER ONE OWNS THE
   INNER ONE'S LIFETIME. Registering the teardown in the instance scope
   is what makes that true rather than aspirational: the inner host
   closes when the outer instance deactivates, in the same reverse
   unwind as every other resource.

   It does NOT count toward `open` — a teardown is not an acquisition
   (`nest/open`). *)
let nest e opts =
  if not e.owner.intransition then
    Types.fail "plugin_release_scope" "nest called outside a lifecycle callback";
  let inner = makehost opts in
  e.scope <-
    e.scope @ [ { sfn = Some (fun () -> close inner); done_ = false;
                  counts = false } ];
  e.inner <- Some inner;
  inner

(* ------------------------------------------------------------------ *)
(* documents                                                           *)
(* ------------------------------------------------------------------ *)

(* Empty the target and refill it, so callers holding the reference see
   the new values. A definition's callbacks close over the options map
   they were handed at `define`; replacing the reference would leave
   every binding reading the values the first apply gave it. *)
let refill target source =
  List.iter (fun k -> V.del target k) (V.keys target);
  List.iter (fun k -> V.set target k (V.get source k)) (V.keys source)

let shapeof h r =
  match Catalog.get h.hcatalog (Ref.refname r) with
  | Some d -> d.shape
  | None -> V.vnull

let apply h doc profile =
  guard h;
  let inp = V.vmap () in
  V.set inp "doc" doc;
  V.set inp "profile" (if V.is_null profile then h.profile else profile);
  V.set inp "keys" h.keys;
  V.set inp "reserved" h.reserved;
  let norm = Config.normalizeconfig inp in

  let want = List.map V.as_str (V.items (V.get norm "order")) in
  let optionsof = V.vmap () in
  List.iter
    (fun r ->
      let oin = V.vmap () in
      V.set oin "ref" (V.vstr r);
      V.set oin "doc" doc;
      V.set oin "profile" (if V.is_null profile then h.profile else profile);
      V.set oin "shape" (shapeof h r);
      if V.is_map h.defaults then
        V.set oin "hostdefaults" (V.get h.defaults (Ref.refname r));
      V.set optionsof r (Config.resolveoptions oin))
    want;

  let instancespec = V.get norm "instance" in
  let wantlive ent =
    V.is_map ent && V.truthy (V.get ent "active")
    && "eager" = V.as_str (V.get ent "start")
  in

  (* --- phase 1: deactivations and unloads, in REVERSE load order --- *)
  let drop =
    List.filter
      (fun e ->
        "declared" <> e.status && not (wantlive (V.get instancespec e.iref)))
      h.instances
  in
  let drop =
    List.map (fun e -> e.iref)
      (List.stable_sort
         (fun a b ->
           if a.pos <> b.pos then compare b.pos a.pos else compare b.iref a.iref)
         drop)
  in
  List.iter (unload h) drop;

  (* --- phase 2: declare and patch EVERYTHING, in load order -------- *)
  List.iter
    (fun r ->
      let ent = V.get instancespec r in
      let spec =
        { nospec with sorder = V.get ent "order";
          spos = Some (V.as_num (V.get ent "pos")) }
      in
      let e = declare h r spec in
      (* The bar is REASSERTED ON EVERY APPLY, in both directions — a
         document that turns the instance back on clears it, which is
         the whole point of a config switch. *)
      e.barred <- not (V.truthy (V.get ent "active"));
      refill e.options (V.get optionsof r);
      e.order <- V.get ent "order";
      e.pos <- V.as_num (V.get ent "pos"))
    want;

  (* --- phase 3: loads, then phase 4: activations, in load order ---- *)
  List.iter
    (fun r -> if wantlive (V.get instancespec r) then ignore (load h r nospec))
    want;
  List.iter
    (fun r -> if wantlive (V.get instancespec r) then ignore (activate h r))
    want

let setoptions h r patch =
  guard h;
  let e = need h r in
  let previous = V.clone e.options in
  let inp = V.vmap () in
  V.set inp "ref" (V.vstr e.iref);
  V.set inp "shape" (shapeof h e.iref);
  V.set inp "doc" (V.vmap ());
  V.set inp "patch" (Types.mergevalue previous patch);
  refill e.options (Config.resolveoptions inp);

  if "live" = e.status then
    match e.idef.reconfigure with
    | Some f ->
      h.intransition <- true;
      h.phase <- "reconfigure";
      let finish () = h.intransition <- false; h.phase <- "" in
      (match f e e.options previous with
       | () -> finish ()
       | exception err -> finish (); raise err)
    | None ->
      (* Always correct and sometimes expensive; `reconfigure` exists
         to make the common case cheap (§9.4). *)
      ignore (deactivate h e.iref);
      ignore (activate h e.iref)
