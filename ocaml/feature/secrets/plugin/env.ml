(* VENDORED: @voxgig/plugin sdk-20260908-1556-0 (ocaml/src/env.ml) *)
(* Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* Environment overrides (§9.5) — level 7 of the ladder.

   One prefix, so nothing drifts: `VOXGIG_PLUGIN_*`.

     VOXGIG_PLUGIN_PROFILE            the profile name
     VOXGIG_PLUGIN_<REF>_<PATH>       one option
     VOXGIG_PLUGIN_ACTIVE/INACTIVE    comma-separated refs, INACTIVE wins

   THE ENCODING IS LOSSY, AND THIS SAYS SO RATHER THAN PRETENDING
   OTHERWISE. Ref and path are upper-snake with `$` -> `__` and `.` ->
   `_`. But `_` is legal in a name and in a tag, and the mapping folds
   case, so `retry$fast` and `retry__fast` both encode to
   `RETRY__FAST`.

   Rather than restrict a grammar the rest of the stack already uses,
   the host DETECTS THE COLLISION: it encodes every ref it holds, and a
   key two refs claim is `plugin_env_ambiguous`, naming both.

   Pure: a function over a string map and a ref set, so the corpus
   tests it without touching a real environment. *)

module V = Value

let prefix = "VOXGIG_PLUGIN_"

let encoderef r =
  let buf = Buffer.create (String.length r * 2) in
  String.iter
    (fun c ->
      if '$' = c then Buffer.add_string buf "__"
      else if '.' = c then Buffer.add_char buf '_'
      else if 'a' <= c && c <= 'z' then
        Buffer.add_char buf (Char.uppercase_ascii c)
      else Buffer.add_char buf c)
    r;
  Buffer.contents buf

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

(* Values parse as JSON, FALLING BACK TO STRING — so `8080` is a
   number, `true` is a boolean, `{"a":1}` is a map, and `hello` is the
   string it looks like rather than a parse error. *)
let parsevalue s = try V.parse s with V.Parse_error _ -> V.vstr s

let lower s = String.lowercase_ascii s

let starts_with p s =
  String.length s >= String.length p && String.sub s 0 (String.length p) = p

let split_on c s = String.split_on_char c s

let trim = String.trim

let applyenv input =
  let env = V.get input "env" in
  let env = if V.is_map env then env else V.vmap () in
  let refsin = V.get input "refs" in
  let reserved = V.get input "reserved" in

  let out = V.vmap () in
  let options = V.vmap () in
  let active = V.vlist () in
  let inactive = V.vlist () in
  V.set out "options" options;
  V.set out "active" active;
  V.set out "inactive" inactive;

  (* Encode every ref the host holds, and refuse a key that two of them
     claim. Done UP FRONT so the collision is reported even when no
     environment variable exercises it — a latent ambiguity is still an
     ambiguity, and finding it at deploy time is the failure this
     exists to prevent. *)
  let byencoded = V.vmap () in
  if V.is_list refsin then
    List.iter
      (fun r ->
        let r = Ref.canonref r in
        let e = encoderef r in
        let l = V.get byencoded e in
        let l = if V.is_null l then (let n = V.vlist () in V.set byencoded e n; n)
                else l in
        V.push l (V.vstr r))
      (V.items refsin);

  let encs = V.sortedkeys byencoded in
  List.iter
    (fun e ->
      let claims = V.get byencoded e in
      if 1 < V.len claims then begin
        let a = V.as_str (V.at claims 0) and b = V.as_str (V.at claims 1) in
        let lo = if a <= b then a else b and hi = if a <= b then b else a in
        let d = V.vmap () in
        V.set d "encoded" (V.vstr e);
        V.set d "refs" (V.oflist [ V.vstr lo; V.vstr hi ]);
        Types.fail "plugin_env_ambiguous"
          ("refs collide in the environment encoding as " ^ e ^ ": " ^ lo
           ^ ", " ^ hi)
          ~details:d
      end)
    encs;

  (* LONGEST encoded ref first, so `retry$fast` wins over `retry` on
     `RETRY__FAST_MIN`. Shortest-first would read the tag as a path. *)
  let order =
    List.sort
      (fun a b ->
        let la = String.length a and lb = String.length b in
        if la <> lb then compare lb la else compare a b)
      encs
  in

  let plen = String.length prefix in
  List.iter
    (fun key ->
      if starts_with prefix key then begin
        let rest = String.sub key plen (String.length key - plen) in
        let raw = V.get env key in
        let value = if V.is_str raw then V.as_str raw else "" in

        if "PROFILE" = rest then V.set out "profile" (V.vstr value)
        else if "ACTIVE" = rest || "INACTIVE" = rest then begin
          let isactive = "ACTIVE" = rest in
          List.iter
            (fun piece ->
              let piece = trim piece in
              if "" <> piece then begin
                let c = Ref.canonrefs piece in
                (* The reservation covers EVERY input layer (§9.1).
                   VOXGIG_PLUGIN_INACTIVE=station is easier to set than
                   editing a config file, and INACTIVE has the final
                   word — so guarding documents alone would leave the
                   one lever this mechanism exists to deny wide open. *)
                checkreserved c reserved;
                V.push (if isactive then active else inactive) (V.vstr c)
              end)
            (split_on ',' value)
        end
        else begin
          let enc =
            List.find_opt
              (fun cand ->
                rest = cand
                || (String.length rest > String.length cand
                    && starts_with cand rest
                    && '_' = rest.[String.length cand]))
              order
          in
          match enc with
          | None -> ()   (* not for any ref this host holds *)
          | Some enc ->
            let r = V.as_str (V.at (V.get byencoded enc) 0) in
            checkreserved r reserved;
            (* A ref with no path sets nothing. *)
            if rest <> enc then begin
              let pathtext =
                String.sub rest
                  (String.length enc + 1)
                  (String.length rest - String.length enc - 1)
              in
              let segs = split_on '_' pathtext in
              let node = ref (V.get options r) in
              if V.is_null !node then begin
                let n = V.vmap () in
                V.set options r n;
                node := n
              end;
              let rec walk = function
                | [] -> ()
                | [ leaf ] -> V.set !node (lower leaf) (parsevalue value)
                | seg :: rest ->
                  let next = V.get !node (lower seg) in
                  let next =
                    if V.is_map next then next
                    else (let n = V.vmap () in V.set !node (lower seg) n; n)
                  in
                  node := next;
                  walk rest
              in
              walk segs
            end
        end
      end)
    (V.sortedkeys env);

  out
