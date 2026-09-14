(* VENDORED: @voxgig/plugin sdk-20260908-1556-0 (ocaml/src/value.ml) *)
(* Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* The dynamic value, and the JSON reader that fills it (§16).

   NO DEPENDENCIES, not even a JSON library: §16 permits exactly one
   runtime dependency (voxgig/struct) and OCaml has no port of it, so
   the corpus JSON is parsed here. A package graph is also a supply
   chain. This port builds with `ocamlfind` absent and links only
   `str.cmxa`, which ships with the compiler.

   A MUTABLE VALUE, WHICH IS NOT THE OBVIOUS CHOICE IN ML. The corpus
   pins behaviour that depends on aliasing: §9.4's `refill` empties an
   options map and refills it *in place* precisely so a definition's
   callbacks, which closed over that map at `define`, read the new
   values. An immutable map would make `refill` a rebinding the
   callbacks never see, and `apply/idempotent` would fail. So maps and
   lists are mutable, and the persistence ML would prefer is spent
   where it belongs: in `clone`.

   A MAP PRESERVES INSERTION ORDER AND SORTS ON DEMAND. §4 rule 4 makes
   order observable in several places (`keys` is sorted, `pos` is the
   sorted-ref index), so both orders have to be available and the code
   has to say which it means at each use. *)

type t =
  | Null
  | Bool of bool
  | Num of float
  | Str of string
  | List of t list ref
  | Map of (string * t) list ref

(* NONE means "nothing"; SOME NULL means "JSON null". They are
   different answers and several places need both: a `bail` binding
   declining is not one answering null, and a missing export is not an
   export of null. *)
type opt = t option

let vnull = Null
let vbool b = Bool b
let vnum n = Num n
let vstr s = Str s
let vlist () = List (ref [])
let vmap () = Map (ref [])

let oflist items = List (ref items)

let is_null = function Null -> true | _ -> false
let is_bool = function Bool _ -> true | _ -> false
let is_num = function Num _ -> true | _ -> false
let is_str = function Str _ -> true | _ -> false
let is_list = function List _ -> true | _ -> false
let is_map = function Map _ -> true | _ -> false

(* `get` answers Null for a missing key AND for a key holding JSON
   null; `has` distinguishes them, which is what §9.1's "an authored
   null is not an absent key" needs. *)
let get v key =
  match v with
  | Map m -> (try List.assoc key !m with Not_found -> Null)
  | _ -> Null

let has v key =
  match v with Map m -> List.mem_assoc key !m | _ -> false

let set v key value =
  match v with
  | Map m ->
    if List.mem_assoc key !m then
      m := List.map (fun (k, old) -> if k = key then (k, value) else (k, old)) !m
    else m := !m @ [ (key, value) ]
  | _ -> ()

let del v key =
  match v with Map m -> m := List.remove_assoc key !m | _ -> ()

let at v i =
  match v with
  | List l -> (try List.nth !l i with _ -> Null)
  | _ -> Null

let push v item = match v with List l -> l := !l @ [ item ] | _ -> ()

let len = function
  | List l -> List.length !l
  | Map m -> List.length !m
  | _ -> 0

let items = function List l -> !l | _ -> []

let as_str = function Str s -> s | _ -> ""
let as_num = function Num n -> n | _ -> 0.0
let as_bool = function Bool b -> b | _ -> false

(* Keys in INSERTION order. *)
let keys = function Map m -> List.map fst !m | _ -> []

(* Keys SORTED by byte order — §4 rule 4's deterministic walk.
   `String.compare` is byte-wise, not locale-aware, which is what every
   other port's sort does. *)
let sortedkeys v = List.sort compare (keys v)

(* §4 rule 4: truthiness is JSON's. *)
let truthy = function
  | Null -> false
  | Bool b -> b
  | Num n -> 0.0 <> n
  | Str s -> "" <> s
  | _ -> true

(* Deep equality INCLUDING JSON type, which is the half that matters:
   half the ports are written in languages whose `==` says `true == 1`,
   and `capability/match` exists to catch exactly that. OCaml's
   structural `=` would answer this correctly for these constructors,
   but it is written out because it must not silently start comparing
   the `ref` cells by identity if the representation changes. *)
let rec same a b =
  match (a, b) with
  | Null, Null -> true
  | Bool x, Bool y -> x = y
  | Num x, Num y -> x = y
  | Str x, Str y -> x = y
  | List x, List y ->
    List.length !x = List.length !y && List.for_all2 same !x !y
  | Map x, Map y ->
    List.length !x = List.length !y
    && List.for_all
         (fun (k, v) -> List.mem_assoc k !y && same v (List.assoc k !y))
         !x
  | _ -> false

let rec clone = function
  | List l -> List (ref (List.map clone !l))
  | Map m -> Map (ref (List.map (fun (k, v) -> (k, clone v)) !m))
  | v -> v

(* --- json ----------------------------------------------------------- *)

(* An integral float renders as an integer: the corpus's expected values
   are written `1`, not `1.0`, and a port that emits the latter fails
   every comparison for a reason that has nothing to do with the
   behaviour under test. *)
let numstr n =
  if Float.is_integer n && Float.abs n < 1e18 then
    Printf.sprintf "%.0f" n
  else
    let s = Printf.sprintf "%.17g" n in
    s

let escape buf s =
  Buffer.add_char buf '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | '\b' -> Buffer.add_string buf "\\b"
      | '\012' -> Buffer.add_string buf "\\f"
      | c when Char.code c < 0x20 ->
        Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char buf c)
    s;
  Buffer.add_char buf '"'

let rec render buf = function
  | Null -> Buffer.add_string buf "null"
  | Bool true -> Buffer.add_string buf "true"
  | Bool false -> Buffer.add_string buf "false"
  | Num n -> Buffer.add_string buf (numstr n)
  | Str s -> escape buf s
  | List l ->
    Buffer.add_char buf '[';
    List.iteri
      (fun i v ->
        if 0 < i then Buffer.add_char buf ',';
        render buf v)
      !l;
    Buffer.add_char buf ']'
  | Map _ as m ->
    (* SORTED, so two values that are `same` render identically. *)
    Buffer.add_char buf '{';
    List.iteri
      (fun i k ->
        if 0 < i then Buffer.add_char buf ',';
        escape buf k;
        Buffer.add_char buf ':';
        render buf (get m k))
      (sortedkeys m);
    Buffer.add_char buf '}'

let json v =
  let buf = Buffer.create 256 in
  render buf v;
  Buffer.contents buf

exception Parse_error of string

let parse text =
  let n = String.length text in
  let i = ref 0 in
  let fail msg = raise (Parse_error msg) in
  let peek () = if !i < n then Some text.[!i] else None in
  let skip () =
    while
      !i < n
      && (' ' = text.[!i] || '\t' = text.[!i] || '\n' = text.[!i]
        || '\r' = text.[!i])
    do
      incr i
    done
  in
  let lit word =
    let l = String.length word in
    if !i + l <= n && String.sub text !i l = word then (i := !i + l; true)
    else false
  in
  let utf8 buf cp =
    if cp < 0x80 then Buffer.add_char buf (Char.chr cp)
    else if cp < 0x800 then begin
      Buffer.add_char buf (Char.chr (0xC0 lor (cp lsr 6)));
      Buffer.add_char buf (Char.chr (0x80 lor (cp land 0x3F)))
    end
    else if cp < 0x10000 then begin
      Buffer.add_char buf (Char.chr (0xE0 lor (cp lsr 12)));
      Buffer.add_char buf (Char.chr (0x80 lor ((cp lsr 6) land 0x3F)));
      Buffer.add_char buf (Char.chr (0x80 lor (cp land 0x3F)))
    end
    else begin
      Buffer.add_char buf (Char.chr (0xF0 lor (cp lsr 18)));
      Buffer.add_char buf (Char.chr (0x80 lor ((cp lsr 12) land 0x3F)));
      Buffer.add_char buf (Char.chr (0x80 lor ((cp lsr 6) land 0x3F)));
      Buffer.add_char buf (Char.chr (0x80 lor (cp land 0x3F)))
    end
  in
  let hex4 () =
    if !i + 4 > n then fail "bad \\u escape";
    let acc = ref 0 in
    for _ = 1 to 4 do
      let c = text.[!i] in
      let d =
        if '0' <= c && c <= '9' then Char.code c - Char.code '0'
        else if 'a' <= c && c <= 'f' then Char.code c - Char.code 'a' + 10
        else if 'A' <= c && c <= 'F' then Char.code c - Char.code 'A' + 10
        else fail "bad \\u escape"
      in
      acc := (!acc * 16) + d;
      incr i
    done;
    !acc
  in
  let pstring () =
    if !i >= n || '"' <> text.[!i] then fail "expected a string";
    incr i;
    let buf = Buffer.create 16 in
    let fin = ref false in
    while not !fin do
      if !i >= n then fail "unterminated string";
      let c = text.[!i] in
      if '"' = c then (incr i; fin := true)
      else if '\\' <> c then (Buffer.add_char buf c; incr i)
      else begin
        incr i;
        if !i >= n then fail "unterminated escape";
        let e = text.[!i] in
        incr i;
        match e with
        | '"' -> Buffer.add_char buf '"'
        | '\\' -> Buffer.add_char buf '\\'
        | '/' -> Buffer.add_char buf '/'
        | 'n' -> Buffer.add_char buf '\n'
        | 'r' -> Buffer.add_char buf '\r'
        | 't' -> Buffer.add_char buf '\t'
        | 'b' -> Buffer.add_char buf '\b'
        | 'f' -> Buffer.add_char buf '\012'
        | 'u' ->
          let hi = hex4 () in
          let cp =
            if 0xD800 <= hi && hi <= 0xDBFF && !i + 1 < n && '\\' = text.[!i]
               && 'u' = text.[!i + 1]
            then begin
              i := !i + 2;
              let lo = hex4 () in
              0x10000 + ((hi - 0xD800) lsl 10) + (lo - 0xDC00)
            end
            else hi
          in
          utf8 buf cp
        | _ -> fail "bad escape"
      end
    done;
    Buffer.contents buf
  in
  let rec value () =
    skip ();
    match peek () with
    | None -> fail "unexpected end of input"
    | Some 'n' -> if lit "null" then Null else fail "bad literal"
    | Some 't' -> if lit "true" then Bool true else fail "bad literal"
    | Some 'f' -> if lit "false" then Bool false else fail "bad literal"
    | Some '"' -> Str (pstring ())
    | Some '[' ->
      incr i;
      let out = vlist () in
      skip ();
      if Some ']' = peek () then (incr i; out)
      else begin
        let fin = ref false in
        while not !fin do
          push out (value ());
          skip ();
          match peek () with
          | Some ',' -> incr i
          | Some ']' -> incr i; fin := true
          | _ -> fail "expected , or ] in array"
        done;
        out
      end
    | Some '{' ->
      incr i;
      let out = vmap () in
      skip ();
      if Some '}' = peek () then (incr i; out)
      else begin
        let fin = ref false in
        while not !fin do
          skip ();
          let key = pstring () in
          skip ();
          if Some ':' <> peek () then fail "expected : in object";
          incr i;
          set out key (value ());
          skip ();
          match peek () with
          | Some ',' -> incr i
          | Some '}' -> incr i; fin := true
          | _ -> fail "expected , or } in object"
        done;
        out
      end
    | Some _ ->
      (* JSON's number grammar is STRICT, and 9.5 makes that observable:
         env values parse as JSON falling back to string, so anything
         this reader accepts loosely silently becomes a number where the
         canonical keeps the authored string. [1e], [1.], [01], [.5] and
         a bare [-] are all errors to JSON.parse; only [-0] and [1e5]
         are not.

           number = [ '-' ] int [ frac ] [ exp ]
           int    = '0' | digit1-9 *digit
           frac   = '.' 1*digit
           exp    = ('e'|'E') [ '+' | '-' ] 1*digit *)
      let start = !i in
      let digit () = !i < n && '0' <= text.[!i] && text.[!i] <= '9' in
      if Some '-' = peek () then incr i;
      if not (digit ()) then fail "bad number";
      if '0' = text.[!i] then incr i
      else while digit () do incr i done;
      if !i < n && '.' = text.[!i] then begin
        incr i;
        if not (digit ()) then fail "bad number";
        while digit () do incr i done
      end;
      if !i < n && ('e' = text.[!i] || 'E' = text.[!i]) then begin
        incr i;
        if !i < n && ('+' = text.[!i] || '-' = text.[!i]) then incr i;
        if not (digit ()) then fail "bad number";
        while digit () do incr i done
      end;
      if start = !i then fail "unexpected character";
      (* `float_of_string_opt`, not `float_of_string`: a bare `-` or a
         truncated `1e` reaches here from `env`'s parse-or-string
         fallback, and a JSON reader that RAISES on a bad number rather
         than reporting one turns "this env value is a string" into a
         crash. §9.5 says values parse as JSON falling back to string,
         and the fallback can only catch a Parse_error. *)
      match float_of_string_opt (String.sub text start (!i - start)) with
      | Some f -> Num f
      | None -> fail "bad number"
  in
  let out = value () in
  skip ();
  if !i <> n then fail "trailing content";
  out
