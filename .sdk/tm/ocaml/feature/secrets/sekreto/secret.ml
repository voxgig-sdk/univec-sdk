(* VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ocaml/src/secret.ml) *)
(* Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* What a secret is called, what a provider is, and what sekreto refuses.

   The floor the whole library stands on: the error type, the `provider`
   record, the pure name functions every kind shares, and redaction. It
   reads nothing, opens nothing and depends on nothing - not even on
   voxgig/plugin.

   It is a separate module from `Sekreto` only because OCaml compiles a
   module before anything that uses it, and the facade needs the four
   built-in kinds, which need this. `Sekreto` re-exports every name below,
   so a caller writes `Sekreto.envkey` and never has to know.

   A port of typescript/src/Sekreto.ts, which is canonical. *)

(* Anything sekreto refuses to do: a bad name, a missing secret, a provider
   that could not be reached. The message is the whole contract - no code,
   no fields, no cause. *)
exception Sekreto_error of string

(* The conformance runner reads a subject's failure with
   `Printexc.to_string`, and so does any OCaml host that catches this.
   Without a printer the message would be reported as
   `Secret.Sekreto_error("...")`, and the corpus pins refusal messages
   byte for byte. *)
let () = Printexc.register_printer (function Sekreto_error m -> Some m | _ -> None)

let fail message = raise (Sekreto_error message)

(* A source of secrets.

   A record of two functions rather than a class or a module type: the
   provider set is open, a provider carries its own state in its closures,
   and a caller can hand in one of its own with no ceremony. *)
type provider = {
  (* The value, or None if this provider does not have it. *)
  lookup : string -> string option;
  (* A short description, shown by `sources`. *)
  describe : unit -> string;
}

(* ---- pure name functions -------------------------------------------- *)

(* Drop a suffix if it is there. `.` and `_` both appear in names, so this
   is spelled out rather than reached for through a pattern. *)
let dropsuffix (text : string) (suffix : string) : string =
  let tlen = String.length text and slen = String.length suffix in
  if tlen >= slen && String.sub text (tlen - slen) slen = suffix then
    String.sub text 0 (tlen - slen)
  else text

(* Split on the literal dot, KEEPING trailing empties, so that `a.` is two
   segments and not one. *)
let segments (name : string) : string list = String.split_on_char '.' name

(* A segment is one or more of [a-z0-9_], scanned rather than matched.

   The obvious `^[a-z0-9_]+$` is not the check it looks like: in several
   regex dialects `$` also matches before a final newline, and four ports
   accepted `api.token\n` because of it. The corpus pins that case, and
   `api\n.token` and `api.token\r` with it. A character scan cannot have
   the bug. *)
let validsegment (part : string) : bool =
  "" <> part
  && String.for_all (fun ch -> ('a' <= ch && ch <= 'z') || ('0' <= ch && ch <= '9') || '_' = ch) part

(* Is this a well-formed secret name? Never raises. *)
let validname (name : string) : bool =
  "" <> name && List.for_all validsegment (segments name)

(* The name, or a Sekreto_error. Every entry point checks its name here. *)
let checkname (name : string) : string =
  if not (validname name) then fail ("sekreto: invalid name: " ^ name);
  name

(* ASCII uppercasing, deliberately locale-invariant: a Turkish locale turns
   `i` into a dotted capital on several platforms, and `api.token` would
   stop being `API_TOKEN`. *)
let upper (text : string) : string = String.uppercase_ascii text

(* The environment-variable key for a name: `api.token` -> `API_TOKEN`.

   The prefix is NOT uppercased - it is given exactly as it will appear. *)
let envkey ?(prefix = "") (name : string) : string =
  prefix ^ upper (String.concat "_" (segments (checkname name)))

(* Where a name lives in a KV vault. *)
type vaultref = { path : string; field : string }

(* `api.token` -> `api` / `token`.

   A single-segment name has no path of its own, so it becomes a secret of
   that name with the conventional field `value`. *)
let vaultref (name : string) : vaultref =
  let parts = segments (checkname name) in
  match parts with
  | [ only ] -> { path = only; field = "value" }
  | _ ->
    let count = List.length parts in
    let head = List.filteri (fun index _ -> index < count - 1) parts in
    { path = String.concat "/" head; field = List.nth parts (count - 1) }

(* A name flattened to one segment: `api.token` -> `api_token` (GCP Secret
   Manager, `_`) or `api-token` (Azure Key Vault, `-`).

   Those stores have no path hierarchy and reject dots in ids, so the dots
   become the store's conventional separator. With `-` as the separator,
   underscores flatten too: Azure Key Vault's alphabet is letters, digits
   and hyphens only, and a valid sekreto name like `with_underscore` must
   still be representable there. *)
let flatname (name : string) (sep : string) : string =
  let flat = String.concat sep (segments (checkname name)) in
  if "-" = sep then String.concat "-" (String.split_on_char '_' flat) else flat

(* The AWS SSM Parameter Store name for a name: dots become the path
   hierarchy, rooted at `/` (or at a prefix): `db.pass.main` ->
   `/db/pass/main`, or `/app/db/pass/main` under prefix `/app`. *)
let awsparam ?(prefix = "") (name : string) : string =
  let checked = checkname name in
  let base = if "" <> prefix && not (String.starts_with ~prefix:"/" prefix) then "/" ^ prefix else prefix in
  let base = dropsuffix base "/" in
  base ^ "/" ^ String.concat "/" (segments checked)

(* Newline, carriage return, tab, backslash and double quote are the five
   escapes a double-quoted .env value may carry. ANY OTHER escape is
   preserved as backslash plus character, and a trailing backslash is
   literal - a scan, not a chain of replacements. *)
let unescape (text : string) : string =
  let out = Buffer.create (String.length text) in
  let index = ref 0 in
  let len = String.length text in

  while !index < len do
    if '\\' = text.[!index] && !index + 1 < len then begin
      let next = text.[!index + 1] in
      index := !index + 2;
      match next with
      | 'n' -> Buffer.add_char out '\n'
      | 'r' -> Buffer.add_char out '\r'
      | 't' -> Buffer.add_char out '\t'
      | '\\' -> Buffer.add_char out '\\'
      | '"' -> Buffer.add_char out '"'
      | other ->
        Buffer.add_char out '\\';
        Buffer.add_char out other
    end
    else begin
      Buffer.add_char out text.[!index];
      incr index
    end
  done;

  Buffer.contents out

let istrimmable = function ' ' | '\t' | '\n' | '\r' | '\012' -> true | _ -> false

let trim (text : string) : string =
  let len = String.length text in
  let start = ref 0 and stop = ref len in
  while !start < !stop && istrimmable text.[!start] do incr start done;
  while !stop > !start && istrimmable text.[!stop - 1] do decr stop done;
  String.sub text !start (!stop - !start)

(* Set a key in an insertion-ordered association list; a later duplicate
   overwrites in place. *)
let assocset (entries : (string * string) list) (key : string) (value : string) :
    (string * string) list =
  if List.mem_assoc key entries then
    List.map (fun (k, v) -> if k = key then (k, value) else (k, v)) entries
  else entries @ [ (key, value) ]

(* Parse `.env` text into raw keys and values, in the order they appear.

   There is no `.env` standard, so this function is the specification.
   Deliberately small: `KEY=value`, an optional `export`, `#` comments on
   their own line, and single- or double-quoted values (double quotes also
   unescape). A line with no `=`, or with an empty key, is skipped in
   silence rather than aborting the lines after it. *)
let parsedotenv (text : string) : (string * string) list =
  let out = ref [] in

  List.iter
    (fun rawline ->
      let line = trim (dropsuffix rawline "\r") in

      if "" <> line && '#' <> line.[0] then begin
        let entry =
          if String.starts_with ~prefix:"export " line then
            trim (String.sub line 7 (String.length line - 7))
          else line
        in

        match String.index_opt entry '=' with
        | Some eq when 0 < eq ->
          let key = trim (String.sub entry 0 eq) in
          let value = trim (String.sub entry (eq + 1) (String.length entry - eq - 1)) in
          let vlen = String.length value in

          let value =
            if 2 <= vlen && '"' = value.[0] && '"' = value.[vlen - 1] then
              unescape (String.sub value 1 (vlen - 2))
            else if 2 <= vlen && '\'' = value.[0] && '\'' = value.[vlen - 1] then
              String.sub value 1 (vlen - 2)
            else value
          in

          out := assocset !out key value
        (* No `=` at all, or an empty key: skipped, and the rest of the file
           is still read. *)
        | _ -> ()
      end)
    (String.split_on_char '\n' text);

  !out

(* Every occurrence of `needle` in `text` replaced by `into`, literally.

   Not a pattern substitution: a secret containing pattern metacharacters
   must not be interpreted as one. *)
let replaceall (text : string) (needle : string) (into : string) : string =
  if "" = needle then text
  else begin
    let out = Buffer.create (String.length text) in
    let nlen = String.length needle and tlen = String.length text in
    let index = ref 0 in

    while !index < tlen do
      if !index + nlen <= tlen && String.sub text !index nlen = needle then begin
        Buffer.add_string out into;
        index := !index + nlen
      end
      else begin
        Buffer.add_char out text.[!index];
        incr index
      end
    done;

    Buffer.contents out
  end

(* Replace known secret values in text with `[redacted]`.

   Only values of four characters or more are replaced: shorter ones are too
   likely to appear in ordinary text, and redacting them would make logs
   unreadable without making them safer.

   Longest first, always, so that a value which is a prefix of another
   cannot redact the shorter half and leave the rest on the page. The
   corpus pins both arrival orders of the same pair, so the case cannot pass
   by luck. The sort is over a COPY: `values` is the caller's, and it is the
   live `seen` list when this is called through a Sekreto. *)
let redact (text : string) (values : string list) : string =
  let usable = List.filter (fun value -> 4 <= String.length value) values in
  let ordered =
    List.stable_sort (fun l r -> compare (String.length r) (String.length l)) usable
  in
  List.fold_left (fun out value -> replaceall out value "[redacted]") text ordered

(* The store name a provider answers to when nothing says otherwise.

   `describe()` opens with the provider's kind - `hashicorp:...`,
   `dotenv:...`, plain `env` - so the kind is the natural default, and a
   custom provider gets a sensible name without implementing anything
   extra. *)
let storename (provider : provider) : string =
  let text = provider.describe () in
  match String.index_opt text ':' with
  | None -> text
  | Some at -> String.sub text 0 at


(* ---- two string searches ---------------------------------------------

   `Str` is not linked - it is a third regex dialect - so substring search
   is written out. Both live here rather than beside the AWS signer they
   were first written for: `safeaddr` and `checkaddr` need them, and the
   core links no plugin. *)

(* The first index at which `needle` occurs in `hay`, or nothing. *)
let findsub (hay : string) (needle : string) : int option =
  let hlen = String.length hay and nlen = String.length needle in
  let rec walk index =
    if index + nlen > hlen then None
    else if String.sub hay index nlen = needle then Some index
    else walk (index + 1)
  in
  walk 0

(* The first index at which `text` holds any of `chars`, or nothing. *)
let splitfirst (text : string) (chars : string) : int option =
  let len = String.length text in
  let rec walk index =
    if index >= len then None
    else if String.contains chars text.[index] then Some index
    else walk (index + 1)
  in
  walk 0
