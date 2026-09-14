(* VENDORED: @voxgig/plugin sdk-20260908-1556-0 (ocaml/src/point.ml) *)
(* Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* Extension points (§6). Three kinds, chosen because they are what the
   two existing systems actually needed, and no more.

   A PLUGIN NEVER MUTATES THE HOST. That inversion is what makes
   deactivation possible: sdkgen's `utility.fetcher = wrapped` is not
   undoable, but "this instance holds slot 3 of the request chain" is
   undoable in O(1). OSGi named it the whiteboard pattern in 2004, in a
   paper called *Listeners Considered Harmful*, and for exactly this
   reason.

   A CLOSURE IS A CLOSURE, which is the whole difference from the `c`
   port: a chain binding receives its `next` as a function the
   composition built — the same shape the canonical writes — instead of
   c's explicit `Chain *` walked by index. *)

module V = Value

(* A binding answers with an option: None DECLINES, Some v answers.
   `bail` needs the distinction and c reaches it with a NULL pointer;
   here it is the type. *)
type hook = V.t -> V.t option

(* The remaining composition, as seen by one chain binding. A binding
   may CALL it and must not store it — a plugin that stashes `next` and
   calls it after deactivation is a bug the host cannot prevent, and
   saying so is better than pretending otherwise (§6.2). *)
type next = V.t -> V.t
type chainfn = next -> V.t -> V.t

type bound = {
  bref : string;
  bpoint : string;
  (* `provider` ranks by HIGHEST band, unlike hook and chain which run
     lowest first. Kept as declared so the two rules stay visibly
     different rather than one being derived from the other by a reader
     who then gets it backwards. *)
  mutable band : float;
  bhook : hook option;
  bchain : chainfn option;
}

(* Composition: b1(b2(b3(base))), FIRST BINDING OUTERMOST (§6.2). *)
let pointcall bindings base arg =
  let rec callat bs a =
    match bs with
    | [] -> (match base with Some f -> f a | None -> a)
    | b :: rest ->
      (match b.bchain with
       | Some c -> c (fun x -> callat rest x) a
       | None -> callat rest a)
  in
  callat bindings arg

let callhook b arg = match b.bhook with Some h -> h arg | None -> None

(* Fan-out. Return values are ignored except in `bail`.

   §6.1: "fan-out" is not one answer but four. In a language with
   asynchrony, "call every binding" hides a decision — start them all
   and wait, await each in turn, or do not wait — and a design that
   leaves it unsaid gets four different answers from four ports, in the
   concurrency behaviour of production code no corpus entry happens to
   cover. This port is synchronous, so all four modes are sequential
   here and only the ERROR and RETURN handling distinguishes them.

   Answers (result, errors). *)
let pointemit bindings mode arg =
  let errors = V.vlist () in
  if "bail" = mode then begin
    (* Stops at the first binding that RETURNS A VALUE — the "handled,
       stop" case. NONE, AND A JSON NULL, BOTH DECLINE.

       JavaScript can tell null from undefined and almost nothing else
       in the target set can — Go, Python, Ruby, PHP, Lua, Java and C#
       each have exactly one way to say nothing. Making the distinction
       load-bearing would cost every one of them a wrapper type carried
       through the whole dispatch path, to express a difference their
       plugin authors cannot write. §18's budget settles it (§6.1). *)
    let rec go = function
      | [] -> (None, errors)
      | b :: rest -> (
        match callhook b arg with
        | Some v when not (V.is_null v) -> (Some v, errors)
        | _ -> go rest)
    in
    go bindings
  end
  else begin
    let raising = "emit" = mode in
    List.iter
      (fun b ->
        if raising then ignore (callhook b arg)
        else
          (* `emit` raises synchronously; the collecting modes
             gather. *)
          try ignore (callhook b arg) with
          | Types.Plugin_error e ->
            let rec_ = V.vmap () in
            V.set rec_ "code" (V.vstr e.Types.code);
            V.set rec_ "message" (V.vstr e.Types.message);
            V.push errors rec_)
      bindings;
    (None, errors)
  end

(* At most one live implementation (§6.3). The winner is the highest
   band, ties broken by ref sort, and THE LOSERS ARE VISIBLE rather
   than silently ignored. Answers (winner, shadowed refs). *)
let pointprovider bindings exclusive =
  if [] = bindings then (None, V.vlist ())
  else begin
    if exclusive && 1 < List.length bindings then begin
      (* Sorted, so the message names the same pair whatever order the
         bindings arrived in. *)
      let refs = List.sort compare (List.map (fun b -> b.bref) bindings) in
      Types.fail "plugin_point_exclusive"
        ("point is exclusive and has "
         ^ string_of_int (List.length bindings)
         ^ " bindings: " ^ String.concat ", " refs)
        ~details:(Types.details1 "refs" (V.oflist (List.map V.vstr refs)))
    end;
    (* HIGHEST band wins, unlike hook and chain; ties break by ref
       sort, which is a TOTAL order. *)
    let ranked =
      List.stable_sort
        (fun a b ->
          if a.band <> b.band then compare b.band a.band
          else compare a.bref b.bref)
        bindings
    in
    let shadowed =
      V.oflist (List.map (fun b -> V.vstr b.bref) (List.tl ranked))
    in
    (Some (List.hd ranked), shadowed)
  end
