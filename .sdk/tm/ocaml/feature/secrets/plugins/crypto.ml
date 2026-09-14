(* VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ocaml/plugins/crypto.ml) *)
(* Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* SHA-256 and HMAC-SHA256, hand-rolled.

   OCaml's distribution has no cryptographic digest but MD5, so the two
   primitives SigV4 is built from are written out here, straight from FIPS
   180-4 and RFC 2104.

   The one dependency this port takes is OpenSSL, and it is taken for
   TRANSPORT only (plugins/tls_stubs.c). Reaching into libcrypto for a digest
   would widen that exception from "cryptographic transport is not
   hand-rolled" to "cryptography is not hand-rolled", which is not the rule.
   Rust is the worked precedent: `ring` is already inside rustls's closure
   and `rust/src/crypto.rs` still carries both primitives.

   Correctness is not argued from inspection: a SigV4 signature is a chain
   of these two functions, so a single wrong bit anywhere fails the five
   known-answer vectors in the shared spec - one of which is AWS's own
   published `get-vanilla`. *)

let mask = 0xFFFFFFFF

let k =
  [| 0x428a2f98; 0x71374491; 0xb5c0fbcf; 0xe9b5dba5; 0x3956c25b; 0x59f111f1; 0x923f82a4;
     0xab1c5ed5; 0xd807aa98; 0x12835b01; 0x243185be; 0x550c7dc3; 0x72be5d74; 0x80deb1fe;
     0x9bdc06a7; 0xc19bf174; 0xe49b69c1; 0xefbe4786; 0x0fc19dc6; 0x240ca1cc; 0x2de92c6f;
     0x4a7484aa; 0x5cb0a9dc; 0x76f988da; 0x983e5152; 0xa831c66d; 0xb00327c8; 0xbf597fc7;
     0xc6e00bf3; 0xd5a79147; 0x06ca6351; 0x14292967; 0x27b70a85; 0x2e1b2138; 0x4d2c6dfc;
     0x53380d13; 0x650a7354; 0x766a0abb; 0x81c2c92e; 0x92722c85; 0xa2bfe8a1; 0xa81a664b;
     0xc24b8b70; 0xc76c51a3; 0xd192e819; 0xd6990624; 0xf40e3585; 0x106aa070; 0x19a4c116;
     0x1e376c08; 0x2748774c; 0x34b0bcb5; 0x391c0cb3; 0x4ed8aa4a; 0x5b9cca4f; 0x682e6ff3;
     0x748f82ee; 0x78a5636f; 0x84c87814; 0x8cc70208; 0x90befffa; 0xa4506ceb; 0xbef9a3f7;
     0xc67178f2 |]

let initial = [| 0x6a09e667; 0xbb67ae85; 0x3c6ef372; 0xa54ff53a; 0x510e527f; 0x9b05688c;
                 0x1f83d9ab; 0x5be0cd19 |]

let rotr x n = ((x lsr n) lor (x lsl (32 - n))) land mask
let shr x n = (x lsr n) land mask

(* The digest of a message, as 32 raw bytes. *)
let sha256 (message : string) : string =
  let len = String.length message in

  (* 0x80, then zeros until the length lands 8 short of a block, then the
     message length in BITS, big-endian. *)
  let padded = Buffer.create (len + 72) in
  Buffer.add_string padded message;
  Buffer.add_char padded '\x80';
  while (Buffer.length padded + 8) mod 64 <> 0 do
    Buffer.add_char padded '\x00'
  done;
  let bits = len * 8 in
  for shift = 7 downto 0 do
    Buffer.add_char padded (Char.chr ((bits lsr (shift * 8)) land 0xff))
  done;

  let block = Buffer.contents padded in
  let state = Array.copy initial in
  let w = Array.make 64 0 in

  let blocks = String.length block / 64 in

  for index = 0 to blocks - 1 do
    let base = index * 64 in

    for step = 0 to 15 do
      let at = base + (step * 4) in
      w.(step) <-
        (Char.code block.[at] lsl 24)
        lor (Char.code block.[at + 1] lsl 16)
        lor (Char.code block.[at + 2] lsl 8)
        lor Char.code block.[at + 3]
    done;

    for step = 16 to 63 do
      let s0 = rotr w.(step - 15) 7 lxor rotr w.(step - 15) 18 lxor shr w.(step - 15) 3 in
      let s1 = rotr w.(step - 2) 17 lxor rotr w.(step - 2) 19 lxor shr w.(step - 2) 10 in
      w.(step) <- (w.(step - 16) + s0 + w.(step - 7) + s1) land mask
    done;

    let a = ref state.(0) and b = ref state.(1) and c = ref state.(2) and d = ref state.(3) in
    let e = ref state.(4) and f = ref state.(5) and g = ref state.(6) and h = ref state.(7) in

    for step = 0 to 63 do
      let s1 = rotr !e 6 lxor rotr !e 11 lxor rotr !e 25 in
      let ch = (!e land !f) lxor (lnot !e land !g land mask) in
      let temp1 = (!h + s1 + ch + k.(step) + w.(step)) land mask in
      let s0 = rotr !a 2 lxor rotr !a 13 lxor rotr !a 22 in
      let maj = (!a land !b) lxor (!a land !c) lxor (!b land !c) in
      let temp2 = (s0 + maj) land mask in

      h := !g;
      g := !f;
      f := !e;
      e := (!d + temp1) land mask;
      d := !c;
      c := !b;
      b := !a;
      a := (temp1 + temp2) land mask
    done;

    state.(0) <- (state.(0) + !a) land mask;
    state.(1) <- (state.(1) + !b) land mask;
    state.(2) <- (state.(2) + !c) land mask;
    state.(3) <- (state.(3) + !d) land mask;
    state.(4) <- (state.(4) + !e) land mask;
    state.(5) <- (state.(5) + !f) land mask;
    state.(6) <- (state.(6) + !g) land mask;
    state.(7) <- (state.(7) + !h) land mask
  done;

  let out = Bytes.create 32 in
  Array.iteri
    (fun index word ->
      Bytes.set out (index * 4) (Char.chr ((word lsr 24) land 0xff));
      Bytes.set out ((index * 4) + 1) (Char.chr ((word lsr 16) land 0xff));
      Bytes.set out ((index * 4) + 2) (Char.chr ((word lsr 8) land 0xff));
      Bytes.set out ((index * 4) + 3) (Char.chr (word land 0xff)))
    state;

  Bytes.to_string out

(* Lowercase hex, two digits a byte. Uppercase hex is wanted in exactly one
   place in this library, and that is percent-escaping. *)
let hex (raw : string) : string =
  let out = Buffer.create (String.length raw * 2) in
  String.iter (fun ch -> Buffer.add_string out (Printf.sprintf "%02x" (Char.code ch))) raw;
  Buffer.contents out

let sha256hex (message : string) : string = hex (sha256 message)

(* RFC 2104, block size 64. Argument order is (key, data) in every port;
   two standard libraries take it the other way round. *)
let hmac (key : string) (data : string) : string =
  let block = 64 in
  let shortened = if String.length key > block then sha256 key else key in
  let padkey = Bytes.make block '\x00' in
  Bytes.blit_string shortened 0 padkey 0 (String.length shortened);

  let inner = Bytes.create block and outer = Bytes.create block in
  for index = 0 to block - 1 do
    let byte = Char.code (Bytes.get padkey index) in
    Bytes.set inner index (Char.chr (byte lxor 0x36));
    Bytes.set outer index (Char.chr (byte lxor 0x5c))
  done;

  sha256 (Bytes.to_string outer ^ sha256 (Bytes.to_string inner ^ data))
