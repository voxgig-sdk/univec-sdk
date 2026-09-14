(* VENDORED: @voxgig/plugin sdk-20260908-1556-0 (ocaml/src/ref.ml) *)
(* Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* Identity: name+tag, written `name$tag` (§4).

   The four pure functions, and the whole of what `ref` pins. They are
   the first thing a new port implements and the first corpus section
   it passes. *)

module V = Value

let max_ref = 1024

let isnamehead c =
  ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z') || '@' = c

let isnamebody c =
  ('a' <= c && c <= 'z')
  || ('A' <= c && c <= 'Z')
  || ('0' <= c && c <= '9')
  || '.' = c || '~' = c || '_' = c || '-' = c || '/' = c

let istagchar c =
  ('a' <= c && c <= 'z')
  || ('A' <= c && c <= 'Z')
  || ('0' <= c && c <= '9')
  || '.' = c || '~' = c || '_' = c || '-' = c

let namely name =
  let n = String.length name in
  n > 0 && n <= max_ref
  && isnamehead name.[0]
  &&
  let ok = ref true in
  String.iteri (fun i c -> if 0 < i && not (isnamebody c) then ok := false) name;
  !ok

let tagly tag =
  let n = String.length tag in
  (* The empty tag is an ordinary tag (§4 rule 2). The single-instance
     case writes no tag and never learns tags exist. *)
  if 0 = n then true
  else if n > max_ref then false
  else
    let ok = ref true in
    String.iter (fun c -> if not (istagchar c) then ok := false) tag;
    !ok

(* A non-string is not a name. Every port has to answer this the same
   way, and `ref/name` pins it for numbers, nulls and maps alike. *)
let checkname name = V.is_str name && namely (V.as_str name)
let checktag tag = V.is_str tag && tagly (V.as_str tag)

(* Split on the FIRST `$`. Nothing in the grammar decides this — `$` is
   in neither character class — so the corpus is the arbiter (§4 rule
   5), and it picks the split that blames the part actually at fault:
   `a$b$c` is a good name with a bad tag, not the reverse. *)
let split s =
  match String.index_opt s '$' with
  | None -> (s, "")
  | Some cut ->
    (String.sub s 0 cut, String.sub s (cut + 1) (String.length s - cut - 1))

let parseref str =
  if not (V.is_str str) then Types.fail "plugin_bad_name" "ref must be a string";
  let name, tag = split (V.as_str str) in
  if not (namely name) then
    Types.fail "plugin_bad_name"
      ("invalid plugin name: " ^ name)
      ~details:(Types.details1 "name" (V.vstr name));
  if not (tagly tag) then
    Types.fail "plugin_bad_tag"
      ("invalid plugin tag: " ^ tag)
      ~details:(Types.details2 "name" (V.vstr name) "tag" (V.vstr tag));
  let out = V.vmap () in
  V.set out "name" (V.vstr name);
  V.set out "tag" (V.vstr tag);
  out

(* An empty tag NEVER writes the separator, which is the half of
   canonicalization formatref owns: parse tolerates `stripe$`, format
   never produces it, so a round trip is idempotent. *)
let formatref name tag =
  let tagok = V.is_null tag || V.is_str tag in
  let t = if V.is_str tag then V.as_str tag else "" in
  if not (checkname name) then
    Types.fail "plugin_bad_name"
      ("invalid plugin name: " ^ (if V.is_str name then V.as_str name else ""))
      ~details:
        (Types.details1 "name" (if V.is_null name then V.vnull else name));
  if (not tagok) || not (tagly t) then
    Types.fail "plugin_bad_tag"
      ("invalid plugin tag: " ^ t)
      ~details:
        (Types.details2 "name" name "tag"
           (if V.is_null tag then V.vstr "" else tag));
  if "" = t then V.as_str name else V.as_str name ^ "$" ^ t

let canonref str =
  let r = parseref str in
  formatref (V.get r "name") (V.get r "tag")

let canonrefs str = canonref (V.vstr str)

(* The canonical ref this string denotes, or None if it denotes none —
   the TOLERANT half of `canonref`, and the one a requirement name
   needs (§11.1). Capability names are free-form, so `2fa` is a good one
   and no ref could be called that; `canonref` RAISES on those, and
   asking it "is this a ref?" made a legal document kill the host.

   An `option`, so a caller cannot mistake "not a ref" for "the empty
   ref". *)
let tryref str =
  let name, tag = split str in
  if (not (namely name)) || not (tagly tag) then None
  else Some (if "" = tag then name else name ^ "$" ^ tag)

(* `canonref` for internal callers that want the input back unchanged
   when it is not well formed. NEVER use where a bad ref must be
   reported — the corpus pins plugin_bad_name at every public entry. *)
let canon str = match tryref str with Some r -> r | None -> str

(* The name half, for internal callers that only compare. *)
let refname str =
  let name, _ = split str in
  if namely name then name else str
