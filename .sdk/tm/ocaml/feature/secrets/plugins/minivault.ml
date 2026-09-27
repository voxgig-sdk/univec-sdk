(* VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (ocaml/plugins/minivault.ml) *)
(* Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* A mini vault: every secret a project owns, encrypted, in ONE FILE.

   The store to reach for before there is a vault server. There is nothing
   to run and nothing to reach over a socket - the whole store is a single
   binary file - and the same chain that reads it in development reads
   HashiCorp or AWS in production by changing config, which is the reason
   sekreto exists.

   A PLUGIN, not a built-in: this kind needs crypto, which is the line the
   four built-in kinds stay behind. The four primitives come from the
   OpenSSL this port already links, through `plugins/minivault_stubs.c` -
   OCaml's distribution has no cipher at all, and the rule against new
   packages stands. That file's header says why the dependency exception
   now reaches this far.

   THE KEY DECIDES WHAT THE VAULT HOLDS. A master key reads and writes
   every name and mints restricted keys. A restricted key reads the names
   it was granted and CANNOT DERIVE ANY OTHER - the restriction is the
   cryptography rather than a check this code performs, so a copy of the
   file plus a restricted passphrase yields exactly what was granted and
   nothing else. What that does and does not protect is set out in DOCS.md
   under "What the mini vault protects".

   THE FILE FORMAT, which is the contract between the ports:

     magic       4   'SKMV'
     version     1   format
     kdf         1   1 = PBKDF2-HMAC-SHA256
     cipher      1   1 = AES-256-GCM
     reserved    1   0
     keycount    4   uint32
     per key:
       id        1 + bytes      the key id, PLAINTEXT
       salt      1 + bytes
       iters     4              PBKDF2 rounds for this key
       ring      1 + iv, 4 + bytes    sealed under the passphrase
       meta      1 + iv, 4 + bytes    sealed under the vault's meta key
     entrycount  4   uint32
     per entry:
       id        1 + bytes      the blinded lookup id
       name      1 + iv, 4 + bytes    sealed under the vault's name key
       value     1 + iv, 4 + bytes    sealed under that secret's own key

   Integers are big-endian and every length precedes its bytes, so the
   file is written with the same two primitives it is read with.

   NOTHING OUTSIDE A KEY RECORD IS PLAINTEXT. Secret names are sealed, and
   an entry is addressed by a blinded id derived from its own key, so a
   restricted key finds what it was granted without the file ever naming
   the rest. What the file does show anyone is the key ids and how many
   secrets there are.

   A port of typescript/plugins/minivault.ts, which is canonical. The
   bytes are pinned by the vaults in test/fixture rather than left to
   agreement between implementations. *)

open Secret
open Provider

(* ---- the primitives ---------------------------------------------------- *)

external random : int -> string = "sekreto_mv_random"
external hmac : string -> string -> string = "sekreto_mv_hmac"
external pbkdf2 : string -> string -> int -> int -> string = "sekreto_mv_pbkdf2"
external gcmseal : string -> string -> string -> string -> string = "sekreto_mv_seal"
external gcmunseal : string -> string -> string -> string -> string = "sekreto_mv_unseal"

(* ---- the format -------------------------------------------------------- *)

let magic = "SKMV"
let format = 1
let kdf_pbkdf2 = 1
let cipher_aesgcm = 1

(* AES-256-GCM: 32-byte keys, 12-byte nonces, 16-byte tags. *)
let keylen = 32
let ivlen = 12
let taglen = 16
let saltlen = 16

(* The PBKDF2-HMAC-SHA256 round count when a caller names none. *)
let iterations = 210000

(* The key id a vault gets when a caller names none. *)
let masterkey = "master"

(* The export key the vault API is published under, beside the `provider`
   key every kind publishes. *)
let vault_export = "vault"

(* Additional authenticated data. Every blob is bound to its PLACE in the
   file, so no ciphertext can be moved: a restricted key's ring cannot be
   relabelled as the master's, and one secret's value cannot be served
   under a name it was never written for. *)
let aad_ring = "skmv1:ring:"
let aad_meta = "skmv1:meta:"
let aad_name = "skmv1:name"
let aad_secret = "skmv1:secret:"

(* Everything a master reaches is derived from the root key, so rotating
   is one new random value rather than a re-wrap of each part. *)
let label_names = "skmv1:names"
let label_meta = "skmv1:meta"
let label_id = "skmv1:id"

(* The largest key id the format can record.

   A length is written in ONE byte. A longer id wrapped that byte and the
   writer then appended the whole thing, so every field after it shifted:
   a grant with a 300-character id replaced a working vault with an
   unreadable one, and said nothing. Checked where an id is ACCEPTED, so
   the refusal names the id rather than the file. *)
let idmax = 255

let mvfail (why : string) = fail ("sekreto: minivault: " ^ why)

let checkid (id : string) (what : string) : string =
  if "" = id then mvfail what
  else if idmax < String.length id then
    mvfail
      (Printf.sprintf "key id is longer than %d bytes: %s..." idmax
         (String.sub id 0 (min 32 (String.length id))))
  else id

(* Every call into the stubs raises `Failure` on a refusal, which is the
   C side's only way to say so; this turns it into the library's own. *)
let guarded (what : string) (body : unit -> 'a) : 'a =
  try body () with Failure _ -> mvfail what

(* ---- keys -------------------------------------------------------------- *)

(* The key-encryption key a passphrase unwraps a ring with.

   A round count below one is refused in the stub, which is what a damaged
   or hostile file records to make the derivation free. *)
let kek (passphrase : string) (salt : string) (iters : int) : string =
  guarded (Printf.sprintf "unusable round count: %d" iters) (fun () ->
      pbkdf2 passphrase salt iters keylen)

(* The key one named secret's value is encrypted with.

   DERIVED, never stored, for a master: it holds the root key and so
   reaches every name, including ones written after it was made. A
   restricted key holds the derived keys it was granted and nothing that
   produces another, so every other name is ciphertext to it in exactly
   the way it is to a stranger. *)
let secretkey (root : string) (name : string) : string = hmac root (aad_secret ^ name)

(* Where a secret lives in the file, derived from its own key so that
   finding it needs no plaintext name. One-way: an id yields nothing about
   the key that produced it. *)
let entryid (key : string) : string = hmac key label_id

let randombytes (len : int) : string =
  guarded "no randomness available" (fun () -> random len)

(* ---- sealing ----------------------------------------------------------- *)

type sealed = { iv : string; blob : string }

let sameseal (left : sealed) (right : sealed) : bool =
  left.iv = right.iv && left.blob = right.blob

(* The tag rides at the END of the blob, which is where every other port's
   AEAD leaves it and therefore what the format records. *)
let seal (key : string) (plain : string) (aad : string) : sealed =
  let iv = randombytes ivlen in
  { iv; blob = guarded "cannot seal" (fun () -> gcmseal key iv plain aad) }

(* The plaintext, or a refusal. A GCM tag that fails to verify is the only
   evidence there is, and it cannot tell a wrong passphrase from a damaged
   file, so `what` names the attempt and the message admits both. *)
let unseal (key : string) (box : sealed) (aad : string) (what : string) : string =
  if taglen > String.length box.blob || ivlen <> String.length box.iv then
    mvfail (what ^ ": truncated")
  else guarded what (fun () -> gcmunseal key box.iv box.blob aad)

(* ---- base64 ------------------------------------------------------------ *)

(* Here rather than `Http.unbase64`: naming that module would link the
   HTTP client and the TLS binding beneath it into a binary whose only
   store opens nothing, which is the cost the core/plugin split exists to
   remove. *)
let b64alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

let b64 (raw : string) : string =
  let out = Buffer.create ((String.length raw + 2) / 3 * 4) in
  let len = String.length raw in
  let at = ref 0 in

  while !at < len do
    let left = len - !at in
    let byte index = Char.code raw.[!at + index] in
    let triple =
      (byte 0 lsl 16) lor (if 1 < left then byte 1 lsl 8 else 0) lor if 2 < left then byte 2 else 0
    in
    Buffer.add_char out b64alphabet.[(triple lsr 18) land 0x3f];
    Buffer.add_char out b64alphabet.[(triple lsr 12) land 0x3f];
    Buffer.add_char out (if 1 < left then b64alphabet.[(triple lsr 6) land 0x3f] else '=');
    Buffer.add_char out (if 2 < left then b64alphabet.[triple land 0x3f] else '=');
    at := !at + 3
  done;

  Buffer.contents out

(* STRICT. A lenient decoder hands back plausible bytes for a corrupted
   payload, and those bytes are then used AS A KEY. *)
let unb64 (text : string) (what : string) : string =
  let len = String.length text in
  if 0 = len || 0 <> len mod 4 then mvfail ("missing " ^ what)
  else begin
    let out = Buffer.create (len / 4 * 3) in
    let held = ref 0 in
    let bits = ref 0 in
    let pad = ref 0 in

    String.iteri
      (fun index ch ->
        if '=' = ch then begin
          incr pad;
          if 2 < !pad || len - 2 > index + !pad then mvfail ("missing " ^ what)
        end
        else begin
          if 0 <> !pad then mvfail ("missing " ^ what);
          match String.index_opt b64alphabet ch with
          | None -> mvfail ("missing " ^ what)
          | Some value ->
            held := (!held lsl 6) lor value;
            bits := !bits + 6;
            if 8 <= !bits then begin
              bits := !bits - 8;
              Buffer.add_char out (Char.chr ((!held lsr !bits) land 0xff))
            end
        end)
      text;

    Buffer.contents out
  end

(* ---- the file ---------------------------------------------------------- *)

type keyrecord = { kid : string; salt : string; iters : int; ring : sealed; meta : sealed }
type entryrecord = { eid : string; ename : sealed; evalue : sealed }
type vaultfile = { keys : keyrecord list; entries : entryrecord list }

let keyof (file : vaultfile) (id : string) : keyrecord option =
  List.find_opt (fun record -> id = record.kid) file.keys

let entryof (file : vaultfile) (id : string) : entryrecord option =
  List.find_opt (fun record -> id = record.eid) file.entries

(* A cursor, so that every length check is in one place: a truncated vault
   is refused rather than read as a short one. *)
type reader = { raw : string; mutable at : int }

(* Reads `length` bytes, or refuses.

   The bound is checked AGAINST WHAT IS LEFT, never by adding the length
   to the cursor. OCaml's int is 63 bits so the sum cannot wrap here, but
   the check reads the same in every port and is the one that is right
   everywhere. *)
let take (r : reader) (length : int) : string =
  if 0 > length || String.length r.raw - r.at < length then
    mvfail "the vault file is truncated"
  else begin
    let out = String.sub r.raw r.at length in
    r.at <- r.at + length;
    out
  end

let u8 (r : reader) : int = Char.code (take r 1).[0]

let u32 (r : reader) : int =
  let four = take r 4 in
  let byte index = Char.code four.[index] in
  (byte 0 lsl 24) lor (byte 1 lsl 16) lor (byte 2 lsl 8) lor byte 3

let small (r : reader) : string = take r (u8 r)
let large (r : reader) : string = take r (u32 r)

let readsealed (r : reader) : sealed =
  (* The iv is read before the blob, and `let` sequences the two reads; a
     record literal would not, because OCaml leaves the order its fields
     are evaluated in unspecified. *)
  let iv = small r in
  { iv; blob = large r }

let readfile (raw : string) : vaultfile =
  let r = { raw; at = 0 } in

  if magic <> take r 4 then mvfail "not a vault file";

  let version = u8 r in
  if format <> version then mvfail (Printf.sprintf "unsupported format version: %d" version);

  let usedkdf = u8 r in
  let usedcipher = u8 r in
  if kdf_pbkdf2 <> usedkdf || cipher_aesgcm <> usedcipher then
    mvfail (Printf.sprintf "unsupported kdf or cipher: %d/%d" usedkdf usedcipher);
  ignore (u8 r);

  (* A COUNT IS BOUNDED BY WHAT IS LEFT. Each record carries at least a few
     bytes, so a file claiming four billion of them is damaged, and the
     loop would find that out one truncation at a time. *)
  let bounded count =
    if String.length raw - r.at < count then mvfail "the vault file is truncated" else count
  in

  let keycount = bounded (u32 r) in
  let keys =
    List.init keycount (fun _ ->
        let kid = small r in
        let salt = small r in
        let iters = u32 r in
        let ring = readsealed r in
        { kid; salt; iters; ring; meta = readsealed r })
  in

  let entrycount = bounded (u32 r) in
  let entries =
    List.init entrycount (fun _ ->
        let eid = small r in
        let ename = readsealed r in
        { eid; ename; evalue = readsealed r })
  in

  if r.at <> String.length raw then mvfail "the vault file has trailing bytes";

  { keys; entries }

let writeu32 (out : Buffer.t) (value : int) : unit =
  Buffer.add_char out (Char.chr ((value lsr 24) land 0xff));
  Buffer.add_char out (Char.chr ((value lsr 16) land 0xff));
  Buffer.add_char out (Char.chr ((value lsr 8) land 0xff));
  Buffer.add_char out (Char.chr (value land 0xff))

let writesmall (out : Buffer.t) (value : string) : unit =
  Buffer.add_char out (Char.chr (String.length value land 0xff));
  Buffer.add_string out value

let writelarge (out : Buffer.t) (value : string) : unit =
  writeu32 out (String.length value);
  Buffer.add_string out value

let writesealed (out : Buffer.t) (box : sealed) : unit =
  writesmall out box.iv;
  writelarge out box.blob

let writefile (file : vaultfile) : string =
  let out = Buffer.create 1024 in

  Buffer.add_string out magic;
  Buffer.add_char out (Char.chr format);
  Buffer.add_char out (Char.chr kdf_pbkdf2);
  Buffer.add_char out (Char.chr cipher_aesgcm);
  Buffer.add_char out '\000';

  writeu32 out (List.length file.keys);
  List.iter
    (fun record ->
      writesmall out record.kid;
      writesmall out record.salt;
      writeu32 out record.iters;
      writesealed out record.ring;
      writesealed out record.meta)
    file.keys;

  (* SORTED BY ID, which is a blinded value: the file therefore records
     nothing about the order secrets were written in. *)
  let entries = List.sort (fun a b -> compare a.eid b.eid) file.entries in

  writeu32 out (List.length entries);
  List.iter
    (fun record ->
      writesmall out record.eid;
      writesealed out record.ename;
      writesealed out record.evalue)
    entries;

  Buffer.contents out

(* ---- the file on disk --------------------------------------------------- *)

(* Read as BINARY, byte for byte: a vault is full of NULs and of bytes no
   encoding claims. `open_in_bin` rather than `open_in` for the same
   reason, although on a POSIX host the two agree. *)
let slurp (path : string) : string option =
  match open_in_bin path with
  | exception _ -> None
  | handle ->
    let len = in_channel_length handle in
    let raw = really_input_string handle len in
    close_in handle;
    Some raw

(* Owner-only, because a vault file is the whole store, and EXCLUSIVE when
   asked: an exclusive create refuses an existing path and will not follow
   a symlink to make one, which is what makes the temporary below safe to
   name in a directory somebody else can write.

   `Unix.openfile` rather than `open_out_bin`, because the standard
   library has no way to ask for either. *)
let spill (path : string) (raw : string) ~(exclusive : bool) : unit =
  let flags =
    [ Unix.O_WRONLY; Unix.O_CREAT ] @ if exclusive then [ Unix.O_EXCL ] else [ Unix.O_TRUNC ]
  in
  let fd = Unix.openfile path flags 0o600 in
  let bytes = Bytes.of_string raw in
  let len = Bytes.length bytes in
  let at = ref 0 in

  (try
     while !at < len do
       at := !at + Unix.write fd bytes !at (len - !at)
     done;
     Unix.close fd
   with err ->
     (try Unix.close fd with _ -> ());
     (try Unix.unlink path with _ -> ());
     raise err)

let hex (raw : string) : string =
  String.concat "" (List.map (fun ch -> Printf.sprintf "%02x" (Char.code ch))
                      (List.init (String.length raw) (String.get raw)))

(* ---- the vault --------------------------------------------------------- *)

(* What a key may do. `grants` is empty for a master key, which reads and
   writes every name there is.

   An IMMUTABLE record over an immutable list, so the defect the review
   round found in the canonical - a caller flipping its own `write` bit on
   the record it was handed - cannot be written at all. *)
type keyinfo = { key : string; master : bool; write : bool; grants : string list }

(* How a vault file is opened as one key. *)
type options = {
  ofile : string;
  okey : string;
  opassphrase : string;
  oiterations : int;
  (* Make the file, with this key as its master, if it is not there.

     Off by default. A missing vault is far more often a broken deployment
     than a new one, and a store that invents itself where a real vault
     was meant to be answers every read with a miss. *)
  ocreate : bool;
}

let nooptions =
  { ofile = ""; okey = ""; opassphrase = ""; oiterations = 0; ocreate = false }

(* What mints a restricted key. *)
type grantspec = {
  (* The id the new key answers to. *)
  gkey : string;
  (* What unwraps it. Nothing else does, and no master can recover it - a
     lost restricted passphrase is re-granted, never read back. *)
  gpassphrase : string;
  (* The names the key may read. A name that does not exist yet is allowed
     and means what it says: the key reads it once a master writes it. *)
  gnames : string list;
  (* Whether it may overwrite the values it can read. *)
  gwrite : bool;
  (* PBKDF2 rounds for this key, defaulting to the opening handle's. *)
  giterations : int;
}

let nogrant = { gkey = ""; gpassphrase = ""; gnames = []; gwrite = false; giterations = 0 }

(* A handle on one vault file, opened as ONE key.

   Every method answers as that key: `list` shows the names it may read,
   `get` answers for those and misses on the rest, and the master-only
   ones refuse for any other key. Nothing is read or derived until the
   first call that needs the file, so putting a vault in a chain costs no
   key derivation until a secret is actually wanted.

   The derived state is mutable and the rest is not: what a handle
   REMEMBERS changes, and what it IS does not. *)
type vault = {
  vfile : string;
  vkey : string;
  vpassphrase : string;
  viterations : int;
  vcreate : bool;
  mutable vopened : bool;
  mutable vroot : string option;
  mutable vgrants : (string * string) list;
  mutable vwrite : bool;
  (* THE SEALED RING THIS WAS DERIVED FROM, kept so that every later call
     can check the file still says the same thing. A handle that cached
     its keys and never looked again kept reading a vault after its key
     was revoked, which is the one thing `revoke` promises. *)
  mutable vring : sealed option;
}

let file (v : vault) : string = v.vfile
let key (v : vault) : string = v.vkey

(* Forget the derived keys. The next call opens again. *)
let close (v : vault) : unit =
  v.vopened <- false;
  v.vroot <- None;
  v.vgrants <- [];
  v.vwrite <- false;
  v.vring <- None

(* A MASTER'S ring holds the root and no grants; a RESTRICTED key's holds
   grants and no root, even when it was granted nothing. That asymmetry is
   the format rather than a saving: a ring with a root reaches every name
   there will ever be, so a grant list beside it would be a second answer
   to the same question. The canonical omits each absent key outright, and
   these bytes are what the other ports read. *)
let masterring (root : string) : string =
  Json.stringify
    (Json.Obj
       [
         ("v", Json.Num (float_of_int format));
         ("write", Json.Bool true);
         ("root", Json.Str (b64 root));
       ])

let grantring (write : bool) (grants : (string * string) list) : string =
  Json.stringify
    (Json.Obj
       [
         ("v", Json.Num (float_of_int format));
         ("write", Json.Bool write);
         ("grants", Json.Obj (List.map (fun (name, k) -> (name, Json.Str (b64 k))) grants));
       ])

let metaof (master : bool) (write : bool) (names : string list) : string =
  Json.stringify
    (Json.Obj
       [
         ("v", Json.Num (float_of_int format));
         ("master", Json.Bool master);
         ("write", Json.Bool write);
         (* An ARRAY here and an OBJECT in the ring, which is the format
            and not an accident: the ring holds a key per name, and the
            record holds only the names. *)
         ("grants", Json.Arr (List.map (fun name -> Json.Str name) names));
       ])

let sealkey (root : string) (id : string) (passphrase : string) (iters : int) (ring : string)
    (meta : string) : keyrecord =
  let salt = randombytes saltlen in
  {
    kid = id;
    salt;
    iters;
    ring = seal (kek passphrase salt iters) ring (aad_ring ^ id);
    meta = seal (hmac root label_meta) meta (aad_meta ^ id);
  }

(* The one key record a new or rotated vault starts with: a master holding
   the root, granted nothing because it needs nothing. *)
let masterrecord (root : string) (id : string) (passphrase : string) (iters : int) : keyrecord =
  sealkey root id passphrase iters (masterring root) (metaof true true [])

let newvault (id : string) (passphrase : string) (iters : int) : vaultfile =
  { keys = [ masterrecord (randombytes keylen) id passphrase iters ]; entries = [] }

(* Writes a vault file that is not there yet, and REFUSES one that is.

   Straight to the target under an exclusive create rather than through a
   temporary and a rename. A rename REPLACES its destination, so two
   processes creating the same vault both succeeded and the second
   discarded the first one's secrets; a stat beforehand only narrows that
   window. There is nothing to lose by writing the target directly here,
   because there is no file to damage: either this call creates it or it
   fails. *)
let putnew (path : string) (made : vaultfile) : unit =
  match spill path (writefile made) ~exclusive:true with
  | () -> ()
  | exception Unix.Unix_error (Unix.EEXIST, _, _) ->
    mvfail ("vault file already exists: " ^ path)
  | exception _ -> mvfail ("cannot write " ^ path)

(* Replaces the file rather than editing it in place. The rename is what
   makes a concurrent reader see either the old file or the new one, so a
   write interrupted halfway leaves a vault rather than wreckage.

   THE TEMPORARY IS RANDOM AND EXCLUSIVE. `<vault>.<pid>.tmp` is a name
   anyone can predict, and an ordinary create FOLLOWS a symlink, so anyone
   who could write the vault's directory could point that name at another
   file and have the next save truncate it. *)
let save (v : vault) (made : vaultfile) : unit =
  let temp = v.vfile ^ "." ^ hex (randombytes 8) ^ ".tmp" in

  (match spill temp (writefile made) ~exclusive:true with
  | () -> ()
  | exception _ -> mvfail ("cannot write " ^ v.vfile));

  match Sys.rename temp v.vfile with
  | () -> ()
  | exception _ ->
    (* The vault is unchanged either way, and the write error is what the
       caller needs to be told about. *)
    (try Sys.remove temp with _ -> ());
    mvfail ("cannot write " ^ v.vfile)

let bytesof (v : vault) : string =
  match slurp v.vfile with
  | Some raw -> raw
  | None ->
    (* A vault is configured deliberately, with a key. Its absence is a
       broken deployment and never "no secrets here": answering a miss
       would send the chain on to a weaker store, which is the failure
       mode this library most has to avoid. `create` is the caller saying
       the opposite, in writing. *)
    if not v.vcreate then mvfail ("no vault file: " ^ v.vfile)
    else begin
      putnew v.vfile (newvault v.vkey v.vpassphrase v.viterations);
      match slurp v.vfile with
      | Some raw -> raw
      | None -> mvfail ("cannot read " ^ v.vfile)
    end

let jsontrue (held : Json.t) (key : string) : bool =
  match Json.dig held [ key ] with Some (Json.Bool value) -> value | _ -> false

(* The file as this key sees it: parsed every call - it is different bytes
   every time - while the unwrapped ring is kept, because stretching a
   passphrase once per lookup is the cost that caching exists to avoid. *)
let load (v : vault) : vaultfile =
  let made = readfile (bytesof v) in

  match keyof made v.vkey with
  | None ->
    (* REVOKED, or never there. Either way this handle is finished, and
       dropping what it derived is what stops the next call answering from
       memory. *)
    close v;
    mvfail ("no such key: " ^ v.vkey)
  | Some record ->
    (* The file still holds this key, and holds the SAME ring: a key
       revoked and re-granted under another passphrase is a different key
       wearing the id, and re-deriving is what refuses it. *)
    if v.vopened && (match v.vring with Some was -> sameseal was record.ring | None -> false)
    then made
    else begin
      close v;

      let plain =
        unseal
          (kek v.vpassphrase record.salt record.iters)
          record.ring (aad_ring ^ v.vkey)
          ("wrong passphrase for key " ^ v.vkey ^ ", or a damaged vault")
      in

      let held =
        match Json.parse plain with
        | Some (Json.Obj _ as value) -> value
        | _ -> mvfail ("unreadable key ring for " ^ v.vkey)
      in

      let grants =
        match Json.dig held [ "grants" ] with
        | Some (Json.Obj entries) ->
          List.map
            (fun (name, value) ->
              match value with
              | Json.Str text -> (name, unb64 text "a granted key")
              | _ -> mvfail "missing a granted key")
            entries
        | _ -> []
      in

      let root =
        match Json.dig held [ "root" ] with
        | Some (Json.Str text) -> Some (unb64 text "the root key")
        | _ -> None
      in

      v.vroot <- root;
      v.vgrants <- grants;
      v.vwrite <- (None <> root) || jsontrue held "write";
      v.vring <- Some record.ring;
      v.vopened <- true;

      made
    end

(* The root key, or a refusal naming what needed it. *)
let rootof (v : vault) (what : string) : string =
  match v.vroot with
  | Some root -> root
  | None -> mvfail (what ^ " needs a master key, and " ^ v.vkey ^ " is restricted")

(* The key for one name, or nothing when this key cannot reach it. *)
let keyfor (v : vault) (name : string) : string option =
  match v.vroot with
  | Some root -> Some (secretkey root name)
  | None -> List.assoc_opt name v.vgrants

(* Derive the key and read the file NOW rather than at first use. *)
let opened (v : vault) : keyinfo =
  ignore (load v);
  {
    key = v.vkey;
    master = None <> v.vroot;
    write = v.vwrite;
    grants = List.sort compare (List.map fst v.vgrants);
  }

(* The names this key can read, sorted. *)
let list (v : vault) : string list =
  let made = load v in

  let names =
    match v.vroot with
    | Some root ->
      let namekey = hmac root label_names in
      List.map
        (fun entry -> unseal namekey entry.ename aad_name "a secret name is damaged")
        made.entries
    | None ->
      (* A restricted key has no name key, so it reports the grants it can
         actually find: the vault never tells it what else is there. *)
      List.filter_map
        (fun (name, k) -> if None = entryof made (entryid k) then None else Some name)
        v.vgrants
  in

  List.sort compare names

(* The value, or a MISS. A name the vault does not hold and a name this
   key was not granted are both a miss. *)
let get (v : vault) (name : string) : string option =
  ignore (checkname name);
  let made = load v in

  (* OUTSIDE THE GRANT IS A MISS, deliberately. The vault answers as the
     key that opened it, so a name this key cannot read is a name this
     store does not hold for this caller - the same answer a stranger's
     vault gives, and the one that makes a restricted key in front of a
     broader store a workable chain. *)
  match keyfor v name with
  | None -> None
  | Some k -> (
    match entryof made (entryid k) with
    | None -> None
    | Some entry ->
      Some
        (unseal k entry.evalue (aad_secret ^ name) ("the value of " ^ name ^ " is damaged")))

let has (v : vault) (name : string) : bool = None <> get v name

(* Write a value. A master writes any name; a restricted key holding
   `write` overwrites the names it was granted, and creates none. *)
let set (v : vault) (name : string) (value : string) : unit =
  ignore (checkname name);
  let made = load v in

  if not v.vwrite then mvfail ("key " ^ v.vkey ^ " is read-only");

  match keyfor v name with
  | None -> mvfail ("key " ^ v.vkey ^ " was not granted " ^ name)
  | Some k ->
    let box = seal k value (aad_secret ^ name) in
    let id = entryid k in

    let entries =
      if None <> entryof made id then
        List.map
          (fun entry -> if id = entry.eid then { entry with evalue = box } else entry)
          made.entries
      else begin
        (* A NEW NAME NEEDS THE NAME KEY, which only a master holds. So a
           restricted key with `write` updates what it was granted and
           cannot grow the vault, which is what "restricted" has to mean
           for the grant list to stay the whole story. *)
        let root = rootof v ("creating the secret " ^ name) in
        made.entries
        @ [
            {
              eid = id;
              ename = seal (hmac root label_names) name aad_name;
              evalue = box;
            };
          ]
      end
    in

    save v { made with entries }

(* Drop a name. Master only. *)
let remove (v : vault) (name : string) : unit =
  ignore (checkname name);
  let made = load v in
  let root = rootof v "removing a secret" in
  let want = entryid (secretkey root name) in

  if None = entryof made want then mvfail ("no such secret: " ^ name)
  else save v { made with entries = List.filter (fun entry -> want <> entry.eid) made.entries }

(* Every key in the file, with what it may do. Master only. *)
let keys (v : vault) : keyinfo list =
  let made = load v in
  let metakey = hmac (rootof v "listing the keys") label_meta in

  List.map
    (fun record ->
      (* A record written under a root key this one has replaced is still
         in the file and still opens with its own passphrase, so it is
         reported rather than hidden - with what it can do unknown. *)
      match unseal metakey record.meta (aad_meta ^ record.kid) "metadata" with
      | exception Sekreto_error _ ->
        { key = record.kid; master = false; write = false; grants = [] }
      | plain -> (
        match Json.parse plain with
        | Some (Json.Obj _ as noted) ->
          {
            key = record.kid;
            master = jsontrue noted "master";
            write = jsontrue noted "write";
            grants =
              (match Json.dig noted [ "grants" ] with
              | Some (Json.Arr entries) ->
                List.sort compare
                  (List.filter_map
                     (function Json.Str name -> Some name | _ -> None)
                     entries)
              | _ -> []);
          }
        | _ -> mvfail ("unreadable metadata for key " ^ record.kid)))
    made.keys

(* Mint a restricted key. Master only. *)
let grant (v : vault) (spec : grantspec) : unit =
  let made = load v in
  let root = rootof v "granting a key" in

  ignore (checkid spec.gkey "a grant needs a key id");
  if "" = spec.gpassphrase then mvfail "a grant needs a passphrase";
  if None <> keyof made spec.gkey then mvfail ("key already exists: " ^ spec.gkey);

  let names = List.sort compare spec.gnames in
  List.iter (fun name -> ignore (checkname name)) names;

  let record =
    sealkey root spec.gkey spec.gpassphrase
      (if 0 < spec.giterations then spec.giterations else v.viterations)
      (grantring spec.gwrite (List.map (fun name -> (name, secretkey root name)) names))
      (metaof false spec.gwrite names)
  in

  save v { made with keys = made.keys @ [ record ] }

(* Drop a key. Master only.

   Anyone who already copied the file keeps whatever that key could read,
   so revoking bars future reads of the LIVE file and `rotate` is what
   takes a secret back. *)
let revoke (v : vault) (id : string) : unit =
  let made = load v in
  ignore (rootof v "revoking a key");

  if id = v.vkey then mvfail ("a key cannot revoke itself: " ^ id);
  if None = keyof made id then mvfail ("no such key: " ^ id);

  save v { made with keys = List.filter (fun record -> id <> record.kid) made.keys }

(* Take a new root key, re-encrypt every value under it, and DROP EVERY
   OTHER KEY. Master only.

   The other keys go because they must: their rings are sealed under
   passphrases this process does not have, so there is no way to hand them
   keys they can unwrap. Re-grant afterwards. *)
let rotate (v : vault) : unit =
  let made = load v in
  let oldroot = rootof v "rotating the vault" in
  let iters = match keyof made v.vkey with Some record -> record.iters | None -> v.viterations in

  (* Read everything out under the old root before anything changes: once
     the root is replaced the old derived keys are unreachable. *)
  let oldnamekey = hmac oldroot label_names in
  let held =
    List.map
      (fun entry ->
        let name = unseal oldnamekey entry.ename aad_name "a secret name is damaged" in
        ( name,
          unseal (secretkey oldroot name) entry.evalue (aad_secret ^ name)
            ("the value of " ^ name ^ " is damaged") ))
      made.entries
  in

  let root = randombytes keylen in
  let namekey = hmac root label_names in

  let entries =
    List.map
      (fun (name, value) ->
        let k = secretkey root name in
        {
          eid = entryid k;
          ename = seal namekey name aad_name;
          evalue = seal k value (aad_secret ^ name);
        })
      held
  in

  (* SAVE FIRST, adopt second. A handle holding the new root over a file
     that still holds the old one reads nothing and says the vault is
     damaged, which is the wrong story about a failed write. *)
  save v { keys = [ masterrecord root v.vkey v.vpassphrase iters ]; entries };

  (* Dropped rather than replaced: the next call re-derives from the file
     this one just wrote, which is the same rule every other change
     follows. *)
  close v

(* ---- opening and creating ----------------------------------------------- *)

(* Open a vault file as one key.

   The handle is LAZY. Nothing is read, and no passphrase is stretched,
   until a call needs the file - so a chain of ten providers costs ten
   records rather than ten PBKDF2 runs. *)
let openvault (options : options) : vault =
  if "" = options.ofile then mvfail "a vault needs a file";
  if "" = options.opassphrase then mvfail "a vault needs a passphrase";

  let id = if "" = options.okey then masterkey else options.okey in
  ignore (checkid id "a vault needs a key id");

  {
    vfile = options.ofile;
    vkey = id;
    vpassphrase = options.opassphrase;
    viterations = (if 0 < options.oiterations then options.oiterations else iterations);
    vcreate = options.ocreate;
    vopened = false;
    vroot = None;
    vgrants = [];
    vwrite = false;
    vring = None;
  }

(* Make a vault file and answer a handle on its master key.

   Refuses a file that is already there: a vault is created once, and
   overwriting one discards every secret in it along with every key that
   could read them. *)
let createvault (options : options) : vault =
  let v = openvault options in

  (* No stat first: the check and the write would be two steps, and
     `putnew` refuses an existing file in ONE, which is what makes two
     processes racing to create a vault leave one vault. *)
  putnew v.vfile (newvault v.vkey v.vpassphrase v.viterations);

  v

(* ---- the provider -------------------------------------------------------- *)

(* The vaults this module has built.

   voxgig/plugin's values are numbers and strings, not handles, so a
   definition exports the HANDLE of what it made and `vaultof` looks it
   up - exactly as `providerplugin` exports one for the provider.

   The definition's `close` drops the entry, so a chain that was torn down
   and a chain whose construction was refused both hand their vaults back
   and nothing accumulates. `stashedvaults` reads the table, which is what
   makes that checkable rather than merely intended. *)
let vaults : (int, vault) Hashtbl.t = Hashtbl.create 8
let lastvault = ref 0

let stashvault (v : vault) : int =
  incr lastvault;
  Hashtbl.replace vaults !lastvault v;
  !lastvault

let unstashvault (handle : int) : unit = Hashtbl.remove vaults handle
let stashedvaults () : int = Hashtbl.length vaults

(* Reads a vault as one store in a chain.

   The provider is the READ half and nothing more: a chain resolves
   secrets, and writing one is a deliberate act with an API of its own.
   That API is the same handle, reached with `vaultof` off a chain or
   built directly with `openvault`. *)
let minivault_provider (v : vault) : provider =
  { lookup = (fun name -> get v name); describe = (fun () -> "minivault:" ^ file v) }

(* The `minivault` provider kind, as a voxgig/plugin definition.

   Written out rather than built by `providerplugin`, because this
   definition publishes TWO exports: `provider`, the read half every kind
   publishes, and `vault`, the programmatic API. voxgig/plugin's exports
   are how a definition offers an application more than the host's own
   vocabulary, and a store that can only be read is half a vault.

   The `sekreto_error` wrapping is what `providerplugin` would have done:
   plugin wraps a code-less error raised in `define` as
   `plugin_define_failed` and keeps one that already carries a code, so a
   refusal of this provider's own configuration travels under
   `sekreto_error` and comes back out of the host as itself. *)
let plugin () : Defs.definition =
  {
    Defs.dname = "minivault";
    shape = V.vnull;
    define =
      Some
        (fun inst ->
          let spec = specof inst.Defs.options in
          let made =
            (* Configuration is refused HERE, so a mistyped chain fails at
               construction. Reaching the file is not configuration: the
               handle is lazy, and nothing is read or stretched until a
               lookup. *)
            match
              openvault
                {
                  ofile = spec.file;
                  okey = spec.vaultkey;
                  opassphrase = spec.passphrase;
                  oiterations = spec.iterations;
                  ocreate = spec.create;
                }
            with
            | made -> made
            | exception Sekreto_error message ->
              let details = V.vmap () in
              V.set details "ref" (V.vstr inst.Defs.iref);
              V.set details "cause" (V.vstr message);
              Types.fail error_code message ~details
          in
          Host.exportvalue inst provider_export
            (V.vnum (float_of_int (stash (minivault_provider made))));
          Host.exportvalue inst vault_export (V.vnum (float_of_int (stashvault made))));
    activate = None;
    deactivate = None;
    (* THE LIFECYCLE OWNS THE RELEASE, as it does for the provider handle
       beside it: `unload` runs this for a loaded instance and for a
       failed one alike. *)
    close =
      Some
        (fun inst ->
          let held = V.get inst.Defs.exports provider_export in
          if V.is_num held then unstash (int_of_float (V.as_num held));
          let heldvault = V.get inst.Defs.exports vault_export in
          if V.is_num heldvault then unstashvault (int_of_float (V.as_num heldvault)));
    reconfigure = None;
  }

(* The vault behind a store in a chain, as its programmatic API.

   `Sekreto.host` is the voxgig/plugin host the chain is made of, and a
   definition's exports are readable off it by ref. This is the one call
   that turns a store into an API, and it lives here rather than in the
   core because the core knows no plugin.

   With no store named, the unqualified alias answers: one vault in the
   chain resolves whatever it is called, and two refuse rather than
   picking one. *)
let vaultof ?(store = "") (host : Defs.host) : vault =
  let held ref missing =
    match Host.exports host (ref ^ "/" ^ vault_export) with
    | exception _ -> mvfail missing
    | Some value when V.is_num value -> (
      match Hashtbl.find_opt vaults (int_of_float (V.as_num value)) with
      | Some v -> v
      | None -> mvfail missing)
    | _ -> mvfail missing
  in

  if "" = store then held "minivault" "no minivault store in this chain"
  else begin
    (* A NAMED STORE MUST EXIST, and the alias must not stand in for it.
       `Host.exports` falls back to the alias when the exact ref misses,
       so asking for `minivault` in a chain whose only vault is named
       `app` used to hand back the `app` vault - and then write to it.
       Naming a store that is not there refuses, which is the rule the
       whole library follows: `tryget` already means "may not have it", so
       it cannot also mean "may not exist". *)
    let missing = "no minivault store named " ^ store ^ " in this chain" in
    let iref = if "minivault" = store then "minivault" else "minivault$" ^ store in
    if None = Host.instance host iref then mvfail missing else held iref missing
  end
