(* VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ocaml/plugins/tls.ml) *)
(* Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* The OCaml side of the TLS binding.

   Thin on purpose: everything that has to be got right is in
   plugins/tls_stubs.c, next to the OpenSSL calls it is about, and this module
   only decides whether a host is a name or an address, reads
   SEKRETO_CA_BUNDLE, and turns a C-side failure into the library's own
   error type.

   The socket is OCaml's throughout - connected, bounded and closed by
   plugins/http.ml - so the C side never owns a file descriptor. *)

type conn

external tls_connect : Unix.file_descr -> string -> bool -> string -> conn = "sekreto_tls_connect"
external tls_write : conn -> string -> int -> int -> int = "sekreto_tls_write"
external tls_read : conn -> Bytes.t -> int -> int -> int = "sekreto_tls_read"
external tls_close : conn -> unit = "sekreto_tls_close"

(* The cross-port way to add a private CA. Additive, never a replacement,
   and it fails open in silence - see the note in tls_stubs.c. *)
let cabundle = "SEKRETO_CA_BUNDLE"

(* Is this host an IP literal rather than a DNS name?

   It decides two things in the binding: an address is verified against the
   certificate's iPAddress SAN rather than by DNS-name matching, and SNI is
   not sent for it. Asked of the platform's own parser, which is the same
   one the socket layer will use. *)
let isip (host : string) : bool =
  match Unix.inet_addr_of_string host with _ -> true | exception _ -> false

(* Handshake over an already-connected socket, verifying the chain and the
   host name. Any failure raises `Failure`, which plugins/http.ml turns into
   `sekreto: cannot reach ...`. *)
let connect (fd : Unix.file_descr) (host : string) : conn =
  let extra = match Sys.getenv_opt cabundle with Some path -> path | None -> "" in
  tls_connect fd host (isip host) extra

let write (conn : conn) (text : string) (ofs : int) (len : int) : int = tls_write conn text ofs len
let read (conn : conn) (buf : Bytes.t) (ofs : int) (len : int) : int = tls_read conn buf ofs len
let close (conn : conn) : unit = tls_close conn
