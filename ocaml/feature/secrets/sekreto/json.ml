(* VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ocaml/src/json.ml) *)
(* Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* Minimal JSON support for sekreto.

   sekreto adds no third-party dependencies, so it carries just enough JSON
   to read a vault's answer and write the CLI's own line of output. It is
   deliberately not a general-purpose library.

   A variant rather than a stringly-typed value: a vault answering `null`,
   `false`, `0` and "no such key" means four different things, and a closed
   value model keeps them apart at compile time rather than by convention.
   `parse` answers `t option`, where `None` means "this text is not JSON"
   and `Some Null` means "this text is the JSON literal null" - a
   distinction the callers of fetchjson need, since only the first is a
   malformed response.

   A port of typescript/src/Json.ts, which is canonical. *)

type t =
  | Null
  | Bool of bool
  | Num of float
  | Str of string
  | Arr of t list
  | Obj of (string * t) list

(* Raised while reading malformed JSON; never escapes `parse`. *)
exception Json_error of string

(* How deep a response body may nest before it is refused.

   A body arrives before any trust check has been made of what sent it, so
   `[[[[[...` must not be allowed to recurse until the stack gives out. *)
let maxdepth = 128

(* Render a number the way every other port does: a whole number has no
   fractional tail, so a JSON `1` read back and printed stays `1`.

   The fractional case looks for the shortest rendering that reads back as
   the same double, which is what every other port's float printer does. A
   flat `%.17g` would print 0.1 as 0.10000000000000001. *)
let numstr (value : float) : string =
  if Float.is_nan value || value = Float.infinity || value = Float.neg_infinity then "null"
  else if Float.is_integer value && Float.abs value < 9007199254740992.0 then
    Printf.sprintf "%.0f" value
  else
    let rec shortest digits =
      if digits > 17 then Printf.sprintf "%.17g" value
      else
        let text = Printf.sprintf "%.*g" digits value in
        if float_of_string text = value then text else shortest (digits + 1)
    in
    shortest 15

(* ---- accessors ------------------------------------------------------ *)

let asstr = function Str value -> Some value | _ -> None
let asnum = function Num value -> Some value | _ -> None
let asarr = function Arr value -> Some value | _ -> None
let asobj = function Obj value -> Some value | _ -> None

(* Walk nested objects; None the moment a step is not there. *)
let rec dig (value : t) (keys : string list) : t option =
  match keys with
  | [] -> Some value
  | key :: rest -> (
    match value with
    | Obj entries -> (
      match List.assoc_opt key entries with None -> None | Some found -> dig found rest)
    | _ -> None)

let rec write (value : t) (out : Buffer.t) : unit =
  match value with
  | Null -> Buffer.add_string out "null"
  | Bool entry -> Buffer.add_string out (if entry then "true" else "false")
  | Num entry -> Buffer.add_string out (numstr entry)
  | Str entry -> Buffer.add_string out (quote entry)
  | Arr entries ->
    Buffer.add_char out '[';
    List.iteri
      (fun index entry ->
        if 0 < index then Buffer.add_char out ',';
        write entry out)
      entries;
    Buffer.add_char out ']'
  | Obj entries ->
    Buffer.add_char out '{';
    List.iteri
      (fun index (key, entry) ->
        if 0 < index then Buffer.add_char out ',';
        Buffer.add_string out (quote key);
        Buffer.add_char out ':';
        write entry out)
      entries;
    Buffer.add_char out '}'

(* Render a string as a JSON string literal, quotes included.

   Public, because the CLI assembles its one line of output field by field
   rather than by printing a map - the language's own key order is not the
   one every other port prints. *)
and quote (text : string) : string =
  let out = Buffer.create (String.length text + 2) in
  Buffer.add_char out '"';
  String.iter
    (fun ch ->
      match ch with
      | '"' -> Buffer.add_string out "\\\""
      | '\\' -> Buffer.add_string out "\\\\"
      | '\n' -> Buffer.add_string out "\\n"
      | '\r' -> Buffer.add_string out "\\r"
      | '\t' -> Buffer.add_string out "\\t"
      | _ ->
        if 0x20 > Char.code ch then Buffer.add_string out (Printf.sprintf "\\u%04x" (Char.code ch))
        else Buffer.add_char out ch)
    text;
  Buffer.add_char out '"';
  Buffer.contents out

(* Render a value as compact JSON: no spaces, no newlines. *)
let stringify (value : t) : string =
  let out = Buffer.create 64 in
  write value out;
  Buffer.contents out

(* This value as the text a caller would print, or None when there is no
   value at all. A JSON null is "no value": every provider here treats it as
   a miss rather than as the string "null". *)
let text (value : t) : string option =
  match value with
  | Null -> None
  | Str entry -> Some entry
  | Num entry -> Some (numstr entry)
  | Bool entry -> Some (if entry then "true" else "false")
  | other -> Some (stringify other)

(* ---- constructors --------------------------------------------------- *)

let str value = Str value
let num value = Num value
let bool value = Bool value
let arr entries = Arr entries

(* An object, in the order given: a payload's field order is signed. *)
let obj (entries : (string * t) list) : t = Obj entries

(* ---- the parser ----------------------------------------------------- *)

type reader = { text : string; mutable at : int }

let done_ (r : reader) : bool = r.at >= String.length r.text

let skip (r : reader) : unit =
  while
    (not (done_ r))
    && match r.text.[r.at] with ' ' | '\t' | '\n' | '\r' -> true | _ -> false
  do
    r.at <- r.at + 1
  done

let word (r : reader) (want : string) : unit =
  let len = String.length want in
  if r.at + len > String.length r.text || String.sub r.text r.at len <> want then
    raise (Json_error (Printf.sprintf "sekreto: json: bad literal at %d" r.at));
  r.at <- r.at + len

(* One code point as UTF-8. `\uXXXX` reads exactly four hex digits and
   yields one code unit; no port recombines surrogate pairs. *)
let addutf8 (out : Buffer.t) (code : int) : unit =
  if code < 0x80 then Buffer.add_char out (Char.chr code)
  else if code < 0x800 then begin
    Buffer.add_char out (Char.chr (0xc0 lor (code lsr 6)));
    Buffer.add_char out (Char.chr (0x80 lor (code land 0x3f)))
  end
  else begin
    Buffer.add_char out (Char.chr (0xe0 lor (code lsr 12)));
    Buffer.add_char out (Char.chr (0x80 lor ((code lsr 6) land 0x3f)));
    Buffer.add_char out (Char.chr (0x80 lor (code land 0x3f)))
  end

let readstring (r : reader) : string =
  if done_ r || '"' <> r.text.[r.at] then
    raise (Json_error (Printf.sprintf "sekreto: json: expected string at %d" r.at));
  r.at <- r.at + 1;

  let out = Buffer.create 16 in
  let finished = ref false in

  while not !finished do
    if done_ r then raise (Json_error "sekreto: json: unterminated string");
    let ch = r.text.[r.at] in
    r.at <- r.at + 1;

    if '"' = ch then finished := true
    else if '\\' <> ch then Buffer.add_char out ch
    else begin
      if done_ r then raise (Json_error "sekreto: json: unterminated string");
      let escape = r.text.[r.at] in
      r.at <- r.at + 1;
      match escape with
      | '"' -> Buffer.add_char out '"'
      | '\\' -> Buffer.add_char out '\\'
      | '/' -> Buffer.add_char out '/'
      | 'b' -> Buffer.add_char out '\b'
      | 'f' -> Buffer.add_char out '\012'
      | 'n' -> Buffer.add_char out '\n'
      | 'r' -> Buffer.add_char out '\r'
      | 't' -> Buffer.add_char out '\t'
      | 'u' ->
        if r.at + 4 > String.length r.text then
          raise (Json_error "sekreto: json: bad unicode escape");
        let digits = String.sub r.text r.at 4 in
        let code =
          try int_of_string ("0x" ^ digits)
          with _ -> raise (Json_error "sekreto: json: bad unicode escape")
        in
        addutf8 out code;
        r.at <- r.at + 4
      | other -> raise (Json_error (Printf.sprintf "sekreto: json: bad escape [%c]" other))
    end
  done;

  Buffer.contents out

let readnumber (r : reader) : t =
  let start = r.at in

  if (not (done_ r)) && ('-' = r.text.[r.at] || '+' = r.text.[r.at]) then r.at <- r.at + 1;

  while
    (not (done_ r))
    &&
    match r.text.[r.at] with
    | '0' .. '9' | '.' | 'e' | 'E' | '-' | '+' -> true
    | _ -> false
  do
    r.at <- r.at + 1
  done;

  let span = String.sub r.text start (r.at - start) in

  match float_of_string_opt span with
  (* JSON has no infinity, and a token expiry computed from one blows up
     later; 1e999 parses to infinity, so a non-finite result is refused. *)
  | Some value when Float.is_nan value || Float.abs value = Float.infinity ->
    raise (Json_error (Printf.sprintf "sekreto: json: non-finite number [%s]" span))
  | Some value -> Num value
  | None -> raise (Json_error (Printf.sprintf "sekreto: json: bad number [%s]" span))

(* Set a key, keeping its first position if it is already there. *)
let objset (entries : (string * t) list) (key : string) (value : t) : (string * t) list =
  if List.mem_assoc key entries then
    List.map (fun (k, v) -> if k = key then (k, value) else (k, v)) entries
  else entries @ [ (key, value) ]

let rec readvalue (r : reader) (depth : int) : t =
  if depth > maxdepth then raise (Json_error "sekreto: json: too deeply nested");
  if done_ r then raise (Json_error "sekreto: json: unexpected end");

  match r.text.[r.at] with
  | '{' -> readobj r depth
  | '[' -> readarr r depth
  | '"' -> Str (readstring r)
  | 't' ->
    word r "true";
    Bool true
  | 'f' ->
    word r "false";
    Bool false
  | 'n' ->
    word r "null";
    Null
  | _ -> readnumber r

and readobj (r : reader) (depth : int) : t =
  r.at <- r.at + 1;
  skip r;

  if (not (done_ r)) && '}' = r.text.[r.at] then begin
    r.at <- r.at + 1;
    Obj []
  end
  else begin
    let out = ref [] in
    let running = ref true in

    while !running do
      skip r;
      let key = readstring r in
      skip r;

      if done_ r || ':' <> r.text.[r.at] then
        raise (Json_error (Printf.sprintf "sekreto: json: expected ':' at %d" r.at));
      r.at <- r.at + 1;

      skip r;
      out := objset !out key (readvalue r (depth + 1));
      skip r;

      if done_ r then raise (Json_error "sekreto: json: unterminated object");
      if ',' = r.text.[r.at] then r.at <- r.at + 1
      else if '}' = r.text.[r.at] then begin
        r.at <- r.at + 1;
        running := false
      end
      else raise (Json_error (Printf.sprintf "sekreto: json: expected ',' or '}' at %d" r.at))
    done;

    Obj !out
  end

and readarr (r : reader) (depth : int) : t =
  r.at <- r.at + 1;
  skip r;

  if (not (done_ r)) && ']' = r.text.[r.at] then begin
    r.at <- r.at + 1;
    Arr []
  end
  else begin
    let out = ref [] in
    let running = ref true in

    while !running do
      skip r;
      out := readvalue r (depth + 1) :: !out;
      skip r;

      if done_ r then raise (Json_error "sekreto: json: unterminated array");
      if ',' = r.text.[r.at] then r.at <- r.at + 1
      else if ']' = r.text.[r.at] then begin
        r.at <- r.at + 1;
        running := false
      end
      else raise (Json_error (Printf.sprintf "sekreto: json: expected ',' or ']' at %d" r.at))
    done;

    Arr (List.rev !out)
  end

(* Parse JSON text. None for anything unreadable - which the caller must
   tell apart from a literal `null` body, since only the first means the
   store could not answer coherently. No error escapes here. *)
let parse (text : string) : t option =
  if "" = text then None
  else
    try
      let r = { text; at = 0 } in
      skip r;
      let value = readvalue r 0 in
      skip r;
      if not (done_ r) then
        raise (Json_error (Printf.sprintf "sekreto: json: trailing content at %d" r.at));
      Some value
    with _ -> None

(* ---- the same reads on an optional value ----------------------------

   A provider walks a response body, which is `t option` because a store may
   not have answered with JSON at all, without unwrapping at every step. *)

let odig (value : t option) (keys : string list) : t option =
  match value with None -> None | Some found -> dig found keys

let otext (value : t option) : string option =
  match value with None -> None | Some found -> text found

let oasstr (value : t option) : string option =
  match value with None -> None | Some found -> asstr found

let oasarr (value : t option) : t list option =
  match value with None -> None | Some found -> asarr found

let oasobj (value : t option) : (string * t) list option =
  match value with None -> None | Some found -> asobj found
