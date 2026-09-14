(* VENDORED: @voxgig/plugin sdk-20260908-1556-0 (ocaml/src/config.ml) *)
(* Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* The declarative document (§9): normalization, and the ten-level
   precedence ladder.

   TWO FUNCTIONS, AND THE SPLIT BETWEEN THEM IS FORCED.

   `normalizeconfig` normalizes STRUCTURE and ENTRY KEYS. It does not
   merge options, and cannot: §9.4 makes merge behaviour a property of
   the definition's option SHAPE, which normalization has never seen. A
   normalizer that flattened the option layers would make
   `$MERGE: append` unimplementable at load time, because the layers it
   must concatenate would already be collapsed.

   `resolveoptions` applies the ladder, and it is the only place that
   knows the shape. *)

module V = Value

(* §9.1: reservation is all-or-nothing per NAME, so the tagged forms go
   too. A configuration surface that can disable the thing reading it
   is not a surface, it is a trap. *)
let checkreserved r reserved =
  if V.is_list reserved && 0 < V.len reserved then begin
    let name = Ref.refname r in
    if List.exists (fun x -> V.is_str x && V.as_str x = name)
         (V.items reserved)
    then
      Types.fail "plugin_ref_reserved"
        ("ref is reserved by the host: " ^ r)
        ~details:(Types.details1 "ref" (V.vstr r))
  end

(* Both document forms reduce to {ref -> entry} plus the order the form
   implies: array POSITION for the array form, sorted refs for the map
   form. *)
let entriesof src =
  let m = V.vmap () in
  let order = V.vlist () in
  if V.is_null src then (m, order)
  else if V.is_list src then begin
    List.iter
      (fun item ->
        let r = Ref.canonref (V.get item "ref") in
        V.set m r item;
        V.push order (V.vstr r))
      (V.items src);
    (m, order)
  end
  else begin
    (* Map-form refs arrive as KEYS, through a different path than an
       array element's `ref` field — and must canonicalize the same
       way. *)
    List.iter (fun k -> V.set m (Ref.canonrefs k) (V.get src k)) (V.keys src);
    (* Byte-wise, NOT locale-aware and NOT case-folded. All-lowercase
       refs sort identically under all three, so only mixed input
       discriminates: '@' is 0x40, uppercase 0x41-0x5A, lowercase
       0x61-0x7A. *)
    List.iter (fun k -> V.push order (V.vstr k)) (V.sortedkeys m);
    (m, order)
  end

(* PRESENT WINS, EVEN WHEN THE VALUE IS NULL. The canonical is
   [src && undefined !== src[key]], and in JavaScript a key holding
   [null] passes that test -- so a profile's [order: null] clears a base
   ordering block and [active: null] over a base [active: true] is
   falsy, and barred. Testing for non-null instead treated an authored
   null as an absent key, which is 9.1's distinction inverted. *)
let pick src key dflt =
  if V.is_map src && V.has src key then V.get src key else dflt

let listhas l s = List.exists (fun v -> V.is_str v && V.as_str v = s) (V.items l)

let normalizeconfig input =
  let doc = V.get input "doc" in
  let doc = if V.is_map doc then doc else V.vmap () in
  let keyspec = V.get input "keys" in
  let str k d =
    let v = V.get keyspec k in
    if V.is_str v then V.as_str v else d
  in
  let ikey = str "instance" "instance" and dkey = str "default" "default" in
  let reserved = V.get input "reserved" in
  let profile = V.get input "profile" in

  (* The rename is applied at TWO PLACES AND NO OTHERS: the document
     root, and every profile.<name> overlay root (§9.1). A rename
     applied only at the root would leave `profile.prod.sdk`
     untranslated and silently drop every environment override the host
     depends on. Recursing further would be worse: option data is the
     definition's. *)
  let baseinst = V.get doc ikey in
  let basedef = V.get doc dkey in
  let basedef = if V.is_map basedef then basedef else V.vmap () in

  let overlay =
    if V.is_str profile then V.get (V.get doc "profile") (V.as_str profile)
    else V.vnull
  in
  let overinst = if V.is_map overlay then V.get overlay ikey else V.vnull in
  let overdef = if V.is_map overlay then V.get overlay dkey else V.vnull in
  let overdef = if V.is_map overdef then overdef else V.vmap () in

  let basemap, baseorder = entriesof baseinst in
  let overmap, overorder = entriesof overinst in

  List.iter
    (fun m -> List.iter (fun k -> checkreserved k reserved) (V.keys m))
    [ basemap; overmap; basedef; overdef ];

  (* A PARTIAL ARRAY IS NOT A FILTER (§9.1). sdkgen learned this the
     hard way: deriving order from a partial array silently dropped
     config-activated features. Refs in the base but absent from the
     overlay still load, in sorted position AFTER the listed ones. A
     profile may also INTRODUCE a ref the base never declared. *)
  let order = V.vlist () in
  let add l =
    List.iter
      (fun v ->
        let r = V.as_str v in
        if not (listhas order r) then V.push order (V.vstr r))
      (V.items l)
  in
  add overorder;
  (* The remainder keeps the BASE's own order — array position for the
     array form, sorted refs for the map form. Re-sorting here would
     discard an array document's positional order entirely, which is
     the one thing the array form exists to express. *)
  add baseorder;

  let instance = V.vmap () in
  List.iteri
    (fun i rv ->
      let r = V.as_str rv in
      let b = V.get basemap r and o = V.get overmap r in

      (* MERGE THE ENTRIES AS AUTHORED, THEN APPLY DEFAULTS TO THE
         RESULT (§9.3). A safety rule, not a tidiness one: if the
         overlay had its defaults filled in before merging it would
         carry a synthesized active:true and overwrite a base's false —
         silently re-enabling a deliberately disabled integration in
         production. *)
      let active = pick o "active" (pick b "active" (V.vbool true)) in
      let start = pick o "start" (pick b "start" (V.vstr "eager")) in
      let ord = pick o "order" (pick b "order" V.vnull) in

      (* Option layers, levels 3-6, IN LADDER ORDER. Never merged
         here. *)
      let layers = V.vlist () in
      let nm = Ref.refname r in
      let addopts src =
        if V.is_map src && V.has src "options" then
          V.push layers (V.get src "options")
      in
      addopts (V.get basedef nm);
      addopts b;
      addopts (V.get overdef nm);
      addopts o;

      let ent = V.vmap () in
      V.set ent "pos" (V.vnum (float_of_int i));
      V.set ent "active" active;
      V.set ent "start" start;
      V.set ent "optionlayers" layers;
      if not (V.is_null ord) then V.set ent "order" ord;
      V.set instance r ent)
    (V.items order);

  (* `default` DECLARES NOTHING (§9.3). It is a base for every instance
     of that definition; it does not create one, and an entry for a
     name with no instances is inert rather than an error — which is
     what makes a shared library of defaults shippable. *)
  let defout = V.vmap () in
  List.iter (fun k -> V.set defout k (V.get basedef k)) (V.keys basedef);
  List.iter (fun k -> V.set defout k (V.get overdef k)) (V.keys overdef);

  let out = V.vmap () in
  V.set out "instance" instance;
  V.set out "order" order;
  V.set out "default" defout;
  out

(* ------------------------------------------------------------------ *)
(* resolveoptions — §9.3's ten levels, and §9.4's merge directives     *)
(* ------------------------------------------------------------------ *)

(* §9.4: N is an integer of at least 1, and everything else is an
   error.

   `{"deep": 0}` is rejected DESPITE having an obvious reading, because
   "replace at this key" already has a spelling and two spellings for
   one behaviour is the defect class this repo exists to avoid. Without
   the stated domain each port picks its own reading — reject, replace,
   unlimited merge, or clamp to 1 — and the same document resolves
   differently per language. *)
let checkshape shape =
  if V.is_map shape then
    List.iter
      (fun k ->
        let v = V.get shape k in
        if V.is_map v && V.has v "$MERGE" then begin
          let d = V.get v "$MERGE" in
          let bad text =
            Types.fail "plugin_shape_invalid" text
              ~details:(Types.details2 "key" (V.vstr k) "directive" d)
          in
          if V.is_str d then begin
            let w = V.as_str d in
            if "replace" <> w && "append" <> w then
              bad ("invalid $MERGE directive at " ^ k ^ ": " ^ w)
          end
          else if V.is_map d && V.has d "deep" then begin
            let nv = V.get d "deep" in
            let x = V.as_num nv in
            if (not (V.is_num nv)) || (not (Float.is_integer x)) || 1.0 > x then
              bad ("invalid $MERGE deep at " ^ k ^ ": " ^ V.json nv)
          end
          else bad ("invalid $MERGE directive at " ^ k ^ ": " ^ V.json d)
        end)
      (V.keys shape)

(* The shape's non-directive values are the level-1 defaults. *)
let defaultsof shape =
  let out = V.vmap () in
  if V.is_map shape then
    List.iter
      (fun k ->
        let v = V.get shape k in
        if not (V.is_map v && V.has v "$MERGE") then V.set out k v)
      (V.keys shape);
  out

let optsof src key =
  if V.is_null src then None
  (* The array form is equivalent to the map form (§9.1). *)
  else if V.is_list src then
    List.fold_left
      (fun acc item ->
        match acc with
        | Some _ -> acc
        | None ->
          if Ref.canonref (V.get item "ref") = key then
            if V.has item "options" then Some (V.get item "options") else None
          else None)
      None (V.items src)
  else
    List.fold_left
      (fun acc k ->
        match acc with
        | Some _ -> acc
        | None ->
          if Ref.canonrefs k = key then
            let e = V.get src k in
            if V.has e "options" then Some (V.get e "options") else None
          else None)
      None (V.keys src)

(* Merge N levels below this key, replace below that. *)
let rec deepto base over n =
  if 0 >= n then V.clone over
  else if not (V.is_map base && V.is_map over) then V.clone over
  else begin
    let out = V.vmap () in
    List.iter (fun k -> V.set out k (V.get base k)) (V.keys base);
    List.iter
      (fun k -> V.set out k (deepto (V.get out k) (V.get over k) (n - 1)))
      (V.keys over);
    out
  end

(* Merge ONE layer onto the accumulator, honouring the shape's
   directives. The directive holds at EVERY precedence level, not only
   between document levels — §9.4 makes it a property of the shape,
   which does not know which layer a value arrived from. *)
let rec mergeone base over shape =
  if V.is_null over then base
  else if not (V.is_map base && V.is_map over) then V.clone over
  else begin
    let out = V.vmap () in
    List.iter (fun k -> V.set out k (V.get base k)) (V.keys base);
    List.iter
      (fun k ->
        let entry = if V.is_map shape then V.get shape k else V.vnull in
        let directive = if V.is_map entry then V.get entry "$MERGE" else V.vnull in
        let b = V.get out k and o = V.get over k in
        if V.is_str directive && "replace" = V.as_str directive then
          V.set out k (V.clone o)
        else if V.is_str directive && "append" = V.as_str directive then begin
          let merged = V.vlist () in
          if V.is_list b then List.iter (V.push merged) (V.items b);
          if V.is_list o then List.iter (V.push merged) (V.items o)
          else V.push merged o;
          V.set out k merged
        end
        else if V.is_map directive && V.has directive "deep" then
          V.set out k
            (deepto b o (int_of_float (V.as_num (V.get directive "deep"))))
        else if V.is_map b && V.is_map o then
          (* Library default: deep for maps, REPLACE for lists.
             struct.merge is element-wise by index, which for option
             maps is nearly always wrong — ["a"] over ["x","y","z"]
             yielding ["a","y","z"] is the defect station hit on
             secrets.providers. *)
          V.set out k (mergeone b o V.vnull)
        else V.set out k (V.clone o))
      (V.keys over);
    out
  end

let resolveoptions input =
  let shape = V.get input "shape" in
  let shape = if V.is_map shape then shape else V.vmap () in
  checkshape shape;

  let r = Ref.canonref (V.get input "ref") in
  let name = Ref.refname r in
  let doc = V.get input "doc" in
  let doc = if V.is_map doc then doc else V.vmap () in

  let profile = V.get input "profile" in
  let overlay =
    if V.is_str profile then V.get (V.get doc "profile") (V.as_str profile)
    else V.vnull
  in
  let over key = if V.is_map overlay then V.get overlay key else V.vnull in
  let some v = if V.is_null v then None else Some v in

  (* ONE ordered merge, lowest to highest. Levels 3-6 are not two
     namespaces collapsed separately and composed afterwards: that
     inverts the rule that PROFILE SPECIFICITY OUTRANKS DEFINITION
     SPECIFICITY, so a prod per-definition default would lose to a base
     instance value. *)
  let layers =
    [ Some (defaultsof shape);                            (* 1 *)
      some (V.get input "hostdefaults");                  (* 2 *)
      optsof (V.get doc "default") name;                  (* 3 *)
      optsof (V.get doc "instance") r;                    (* 4 *)
      optsof (over "default") name;                       (* 5 *)
      optsof (over "instance") r;                         (* 6 *)
      some (V.get input "env");                           (* 7 *)
      some (V.get input "hostoptions");                   (* 8 *)
      some (V.get input "loadoptions");                   (* 9 *)
      some (V.get input "patch") ]                        (* 10 *)
  in
  List.fold_left
    (fun acc layer ->
      match layer with None -> acc | Some l -> mergeone acc l shape)
    (V.vmap ()) layers
