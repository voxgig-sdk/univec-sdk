(* Struct corpus: drives test.json -> "struct" through the vendored
 * Voxgig_struct implementation, on the vendored @voxgig/omni engine.
 *
 * The engine is NOT in this file and is not hand-written any more: every
 * group below is handed to omni through Omni_resolver (which supersedes the
 * retired test/corpus_runner.ml). What remains here is what actually belongs
 * to this SDK — which corpus group drives which struct function, and how.
 *)

open Voxgig_struct

module O = Omni
module R = Omni_resolver

(* ---------------- subjects that need more than one expression -------- *)

let null_modifier v key parent _inj =
  if v = Str R.nullmark then ignore (setprop parent key Null)
  else (match v with Str s -> ignore (setprop parent key (Str (
      (* replace __NULL__ with null *)
      let b = Buffer.create (String.length s) in
      let nl = String.length R.nullmark in let n = String.length s in let i = ref 0 in
      while !i < n do
        if !i + nl <= n && String.sub s !i nl = R.nullmark then (Buffer.add_string b "null"; i := !i + nl)
        else (Buffer.add_char b s.[!i]; incr i)
      done; Buffer.contents b)))
   | _ -> ())

(* walk/log is authored as one {in, out} pair whose `out.after` is the log of
 * an after-walk. The subject builds that log and returns it; Omni_resolver's
 * `single ~out:["after"]` selects the half the corpus asserts on. *)
let walk_log_subject vin =
  let log = empty_list () in
  let walklog key v parent path =
    ignore (setprop log (Num (float_of_int (size log)))
              (Str (Printf.sprintf "k=%s, v=%s, p=%s, t=%s"
                      (if is_nullish key then stringify Noval else stringify key)
                      (stringify v)
                      (if is_nullish parent then stringify Noval else stringify parent)
                      (pathify path))));
    v in
  ignore (walk ~after:walklog vin);
  log

let walk_copy_subject vin =
  let cur = ref (lst [Noval]) in
  let walkcopy key v _parent path =
    if is_nullish key then begin
      cur := lst [(if ismap v then empty_map () else if islist v then empty_list () else v)];
      v
    end else begin
      let i = size path in
      let nv = if isnode v then begin
          (match !cur with List r -> while List.length !r <= i do r := !r @ [Noval] done | _ -> ());
          let n = if ismap v then empty_map () else empty_list () in
          (match !cur with List r -> r := List.mapi (fun j x -> if j = i then n else x) !r | _ -> ());
          n
        end else v in
      ignore (setprop (getelem !cur (Num (float_of_int (i - 1)))) key nv);
      v
    end in
  ignore (walk ~before:walkcopy vin);
  getelem !cur (Num 0.0)

let walk_depth_subject vin =
  let top = ref Noval and curr = ref Noval in
  let copy key v _parent _path =
    (if is_nullish key || isnode v then begin
        let child = if islist v then empty_list () else empty_map () in
        if is_nullish key then (top := child; curr := child)
        else (ignore (setprop !curr key child); curr := child)
      end else ignore (setprop !curr key v));
    v in
  ignore (walk ~before:copy ~maxdepth:(R.getp vin "maxdepth") (R.getp vin "src"));
  !top

(* ---------------- test groups ---------------- *)

let run_all (r : R.run) =
  let g k = O.jget (R.spec r) k in
  let minor = g "minor" and walks = g "walk" and merges = g "merge"
  and getpaths = g "getpath" and injects = g "inject" and transforms = g "transform"
  and validates = g "validate" and selects = g "select" and nullsem = g "nullsem" in
  let mg n = O.jget minor n in
  let set = R.runset r in

  (* minor *)
  set "minor.isnode" (mg "isnode") (fun v -> Bool (isnode v));
  set "minor.ismap" (mg "ismap") (fun v -> Bool (ismap v));
  set "minor.islist" (mg "islist") (fun v -> Bool (islist v));
  set ~nullflag:false "minor.iskey" (mg "iskey") (fun v -> Bool (iskey v));
  set ~nullflag:false "minor.strkey" (mg "strkey") (fun v -> Str (strkey ~key:v ()));
  set ~nullflag:false "minor.isempty" (mg "isempty") (fun v -> Bool (isempty v));
  set "minor.isfunc" (mg "isfunc") (fun v -> Bool (isfunc v));
  set ~nullflag:false "minor.clone" (mg "clone") clone;
  set "minor.escre" (mg "escre") escre;
  set "minor.escurl" (mg "escurl") escurl;
  set ~nullflag:false "minor.stringify" (mg "stringify")
    (fun vin -> if R.hasp vin "val" then Str (stringify ~maxlen:(R.getp vin "max") (R.getp vin "val"))
      else Str (stringify Noval));
  set ~nullflag:false "minor.jsonify" (mg "jsonify")
    (fun vin -> Str (jsonify ~flags:(R.getp vin "flags") (R.getp vin "val")));
  (* `alt` is read by PRESENCE, not by nullishness: two `minor/getprop`
   * entries pass an EXPLICIT null alt and expect it back, and treating that
   * as "no alt given" answers no-value instead. The retired hand-written
   * runner hid it — its `eqv` matched Noval against Null — which is exactly
   * the leniency the vendored engine does not have. Kept identical in both
   * lanes (as go's `hasAlt` is) so they cannot drift. *)
  set ~nullflag:false "minor.getelem" (mg "getelem")
    (fun vin -> if R.hasp vin "alt" then getelem ~alt:(R.getp vin "alt") (R.getp vin "val") (R.getp vin "key")
      else getelem (R.getp vin "val") (R.getp vin "key"));
  set "minor.delprop" (mg "delprop")
    (fun vin -> delprop (R.getp vin "parent") (R.getp vin "key"));
  set ~nullflag:false "minor.size" (mg "size") (fun v -> vint (size v));
  set ~nullflag:false "minor.slice" (mg "slice")
    (fun vin -> slice ~start:(R.getp vin "start") ~stop:(R.getp vin "end") (R.getp vin "val"));
  set ~nullflag:false "minor.pad" (mg "pad")
    (fun vin -> Str (pad ~padding:(R.getp vin "pad") ~padchar:(R.getp vin "char") (R.getp vin "val")));
  set ~nullflag:false "minor.pathify" (mg "pathify")
    (fun vin -> if R.hasp vin "path" then Str (pathify ~startin:(R.getp vin "from") (R.getp vin "path"))
      else Str (pathify ~startin:(R.getp vin "from") ~absent:true Noval));
  set "minor.items" (mg "items") items;
  set ~nullflag:false "minor.getprop" (mg "getprop")
    (fun vin -> if R.hasp vin "alt" then getprop ~alt:(R.getp vin "alt") (R.getp vin "val") (R.getp vin "key")
      else getprop (R.getp vin "val") (R.getp vin "key"));
  set "minor.setprop" (mg "setprop")
    (fun vin -> setprop (R.getp vin "parent") (R.getp vin "key") (R.getp vin "val"));
  set ~nullflag:false "minor.haskey" (mg "haskey")
    (fun vin -> Bool (haskey (R.getp vin "src") (R.getp vin "key")));
  set "minor.keysof" (mg "keysof") (fun v -> lst (List.map (fun s -> Str s) (keysof v)));
  set ~nullflag:false "minor.join" (mg "join")
    (fun vin -> Str (join ~sep:(R.getp vin "sep")
                       ~url:(match R.getp vin "url" with Bool true -> true | _ -> false)
                       (R.getp vin "val")));
  set ~nullflag:false "minor.typify" (mg "typify") (fun v -> vint (typify v));
  set ~nullflag:false "minor.setpath" (mg "setpath")
    (fun vin -> setpath (R.getp vin "store") (R.getp vin "path") (R.getp vin "val"));
  set "minor.filter" (mg "filter")
    (fun vin -> let check = (match R.getp vin "check" with
        | Str "gt3" -> (fun (_, x) -> match x with Num n -> n > 3.0 | _ -> false)
        | Str "lt3" -> (fun (_, x) -> match x with Num n -> n < 3.0 | _ -> false)
        | _ -> (fun _ -> false)) in
      filter (R.getp vin "val") check);
  set "minor.typename" (mg "typename")
    (fun v -> Str (typename (match v with Num n -> int_of_float n | _ -> 0)));
  set "minor.flatten" (mg "flatten")
    (fun vin -> flatten ?depth:(match R.getp vin "depth" with Num n -> Some (int_of_float n) | _ -> None)
        (R.getp vin "val"));

  (* walk *)
  set "walk.log" (R.single ~out:["after"] (O.jget walks "log")) walk_log_subject;
  set "walk.basic" (O.jget walks "basic")
    (fun vin -> walk ~after:(fun _k v _p path ->
         match v with
         | Str s -> Str (s ^ "~" ^ String.concat "." (List.map js_string (match path with List r -> !r | _ -> [])))
         | _ -> v) vin);
  set "walk.copy" (O.jget walks "copy") walk_copy_subject;
  set ~nullflag:false "walk.depth" (O.jget walks "depth") walk_depth_subject;

  (* merge *)
  set "merge.basic" (R.single (O.jget merges "basic")) (fun v -> merge (clone v));
  set "merge.cases" (O.jget merges "cases") merge;
  set "merge.array" (O.jget merges "array") merge;
  set "merge.integrity" (O.jget merges "integrity") merge;
  set "merge.depth" (O.jget merges "depth")
    (fun vin -> merge ~maxdepth:(R.getp vin "depth") (R.getp vin "val"));

  (* getpath *)
  set "getpath.basic" (O.jget getpaths "basic")
    (fun vin -> getpath (R.getp vin "store") (R.getp vin "path"));
  set "getpath.relative" (O.jget getpaths "relative")
    (fun vin ->
       let dpath = (match R.getp vin "dpath" with
           | Str s -> lst (List.map (fun x -> Str x) (String.split_on_char '.' s))
           | _ -> Noval) in
       let d = { (R.default_injdef ()) with d_dparent = R.getp vin "dparent"; d_dpath = dpath } in
       getpath ~inj:(IDef d) (R.getp vin "store") (R.getp vin "path"));
  set "getpath.special" (O.jget getpaths "special")
    (fun vin ->
       let injm = R.getp vin "inj" in
       let d = { (R.default_injdef ()) with
                 d_base = getprop injm (Str "base"); d_meta = getprop injm (Str "meta");
                 d_dparent = getprop injm (Str "dparent"); d_dpath = getprop injm (Str "dpath");
                 d_key = getprop injm (Str "key") } in
       getpath ~inj:(if is_nullish injm then INone else IDef d) (R.getp vin "store") (R.getp vin "path"));
  set "getpath.handler" (O.jget getpaths "handler")
    (fun vin ->
       let store = R.omap_v ["$TOP", R.getp vin "store"; "$FOO", Func (fun _ _ _ _ -> Str "foo")] in
       let d = { (R.default_injdef ()) with
                 d_handler = Some (fun _inj v _ref _store ->
                     match v with Func f -> f (Obj.magic 0) Noval "" Noval | _ -> v) } in
       getpath ~inj:(IDef d) store (R.getp vin "path"));

  (* inject *)
  set "inject.basic" (R.single (O.jget injects "basic"))
    (fun vin -> inject (clone (R.getp vin "val")) (clone (R.getp vin "store")));
  set "inject.string" (O.jget injects "string")
    (fun vin ->
       let d = { (R.default_injdef ()) with d_modify = Some null_modifier; d_extra = R.getp vin "current" } in
       inject ~inj:(IDef d) (R.getp vin "val") (R.getp vin "store"));
  set "inject.deep" (O.jget injects "deep")
    (fun vin -> inject (R.getp vin "val") (R.getp vin "store"));

  (* transform *)
  set "transform.basic" (R.single (O.jget transforms "basic"))
    (fun vin -> transform (R.getp vin "data") (R.getp vin "spec"));
  List.iter (fun gn ->
      set ("transform." ^ gn) (O.jget transforms gn)
        (fun vin -> transform (R.getp vin "data") (R.getp vin "spec")))
    ["paths"; "cmds"; "each"; "pack"; "ref"];
  set "transform.modify" (O.jget transforms "modify")
    (fun vin ->
       let d = { (R.default_injdef ()) with
                 d_modify = Some (fun v key parent _inj ->
                     (match v with
                      | Str s when not (is_nullish key) && not (is_nullish parent) ->
                        ignore (setprop parent key (Str ("@" ^ s)))
                      | _ -> ()));
                 d_extra = R.getp vin "store" } in
       transform ~inj:(IDef d) (R.getp vin "data") (R.getp vin "spec"));
  set ~nullflag:false "transform.format" (O.jget transforms "format")
    (fun vin -> transform (R.getp vin "data") (R.getp vin "spec"));
  set "transform.apply" (O.jget transforms "apply")
    (fun vin -> transform (R.getp vin "data") (R.getp vin "spec"));

  (* validate *)
  set ~nullflag:false "validate.basic" (O.jget validates "basic")
    (fun vin -> validate (R.getp vin "data") (R.getp vin "spec"));
  List.iter (fun gn ->
      set ("validate." ^ gn) (O.jget validates gn)
        (fun vin -> validate (R.getp vin "data") (R.getp vin "spec")))
    ["child"; "one"; "exact"];
  set ~nullflag:false "validate.invalid" (O.jget validates "invalid")
    (fun vin -> validate (R.getp vin "data") (R.getp vin "spec"));
  set "validate.special" (O.jget validates "special")
    (fun vin ->
       let injm = R.getp vin "inj" in
       let d = { (R.default_injdef ()) with d_meta = getprop injm (Str "meta") } in
       validate ~inj:(if is_nullish injm then INone else IDef d) (R.getp vin "data") (R.getp vin "spec"));

  (* select *)
  List.iter (fun gn ->
      set ("select." ^ gn) (O.jget selects gn)
        (fun vin -> select (R.getp vin "obj") (R.getp vin "query")))
    ["basic"; "operators"; "edge"; "alts"];

  (* nullsem: does a PRESENT key holding a JSON null read as "no value"?
   * Every lane runs {null: false} — the whole point of the section is the
   * distinction the null flag would erase. `alt` is read by PRESENCE, not by
   * nullishness: several entries pass no alt at all, and one passes a null
   * one deliberately. (This section used to be looked up as "sentinels",
   * a name the shipped corpus has never carried — so all six of its groups
   * silently ran ZERO cases. Omni_resolver now names a missing group out
   * loud, which is how that was found.) *)
  set ~nullflag:false "nullsem.getprop" (O.jget nullsem "getprop")
    (fun vin -> if R.hasp vin "alt" then getprop ~alt:(R.getp vin "alt") (R.getp vin "val") (R.getp vin "key")
      else getprop (R.getp vin "val") (R.getp vin "key"));
  set ~nullflag:false "nullsem.getelem" (O.jget nullsem "getelem")
    (fun vin -> if R.hasp vin "alt" then getelem ~alt:(R.getp vin "alt") (R.getp vin "val") (R.getp vin "key")
      else getelem (R.getp vin "val") (R.getp vin "key"));
  set ~nullflag:false "nullsem.getpath" (O.jget nullsem "getpath")
    (fun vin -> getpath (R.getp vin "store") (R.getp vin "path"));
  set ~nullflag:false "nullsem.haskey" (O.jget nullsem "haskey")
    (fun vin -> Bool (haskey (R.getp vin "src") (R.getp vin "key")));
  set ~nullflag:false "nullsem.keysof" (O.jget nullsem "keysof")
    (fun v -> lst (List.map (fun s -> Str s) (keysof v)))

(* ---------------- main ---------------- *)

let () =
  let testfile = if Array.length Sys.argv > 1 then Sys.argv.(1) else "../.sdk/test/test.json" in
  let r = R.make_run testfile "struct" in
  run_all r;
  R.report r ""
