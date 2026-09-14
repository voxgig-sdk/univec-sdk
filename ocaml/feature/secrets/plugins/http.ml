(* VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ocaml/plugins/http.ml) *)
(* Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* Just enough HTTP to ask a vault for a secret.

   OCaml's distribution has sockets and no HTTP client, so this speaks
   HTTP/1.1 over a Unix socket directly: a GET or POST with headers and an
   optional body, a status line, and a response body delimited by
   Content-Length, by chunks, or by the connection closing. That is the
   house rule - HTTP framing is written in-tree - and it is why the port
   binds libssl rather than libcurl.

   https rides plugins/tls.ml, which is the whole of the port's third-party
   surface.

   It is deliberately not a general-purpose client.

   NO REDIRECTS. A vault API does not legitimately redirect, and a followed
   redirect would carry X-Vault-Token to a host `checkaddr` never saw, and
   could downgrade https to http.

   NO PROXIES. Nothing here reads http_proxy, https_proxy or ALL_PROXY. The
   GCP and Azure metadata endpoints are not loopback, and a proxy variable
   in the environment has sent a Vault token in the clear before. *)

open Secret

(* How long reaching a vault may take before it is treated as unreachable.
   Ports carry the same bound. *)
let timeout = 10.0

(* How much of a response body will be read before the store is treated as
   having answered incoherently. Ports carry the same bound.

   Far above anything real - the largest legitimate payload this library
   fetches is Doppler's whole-config download, measured in kilobytes. A
   bound is needed because the timeout is not one: it is per read, so a
   server that keeps sending resets it forever, and the body is accumulated
   in memory before it is parsed. This runs on an application's startup
   path, so the failure is the application never starting. *)
let maxbody = 8 * 1024 * 1024

type response = { status : int; body : string }

(* A url split into the parts a request needs. *)
type target = {
  (* The bare host: what we connect to, and what the certificate is checked
     against. An IPv6 literal appears here without brackets. *)
  host : string;
  (* The authority as it goes in the `Host:` header. An IPv6 literal keeps
     its brackets, because `Host: 2001:db8::1:8200` is not a valid authority
     and an intermediary may reject or misroute it. *)
  authority : string;
  port : int;
  path : string;
  tls : bool;
}

(* A url without its query string, for a message that must not leak one.

   A query here carries the vault path, the secret name or a filter -
   `secretPath=/prod/payments/stripe` - which does not belong in a log. *)
let bare (url : string) : string =
  match String.index_opt url '?' with None -> url | Some at -> String.sub url 0 at

let unreachable (url : string) (why : string) : 'a =
  fail ("sekreto: cannot reach " ^ bare url ^ ": " ^ why)

let split (url : string) : target =
  let rest, tls, defaultport =
    if String.starts_with ~prefix:"https://" url then
      (String.sub url 8 (String.length url - 8), true, 443)
    else if String.starts_with ~prefix:"http://" url then
      (String.sub url 7 (String.length url - 7), false, 80)
    else fail ("sekreto: not an http url: " ^ bare url)
  in

  let authority, path =
    match String.index_opt rest '/' with
    | Some at -> (String.sub rest 0 at, String.sub rest at (String.length rest - at))
    | None -> (rest, "/")
  in

  (* rindex, so that an IPv6 literal's own colons are not mistaken for a
     port separator when one is present. *)
  let hostpart, port =
    match String.rindex_opt authority ':' with
    | Some at
      when at + 1 < String.length authority
           && not (String.ends_with ~suffix:"]" authority) ->
      let text = String.sub authority (at + 1) (String.length authority - at - 1) in
      (String.sub authority 0 at, match int_of_string_opt text with Some p -> p | None -> defaultport)
    | _ -> (authority, defaultport)
  in

  let stripped =
    let len = String.length hostpart in
    if len >= 2 && '[' = hostpart.[0] && ']' = hostpart.[len - 1] then String.sub hostpart 1 (len - 2)
    else hostpart
  in

  (* Re-bracketed only if it really is an IPv6 literal. *)
  let header = if String.contains stripped ':' then "[" ^ stripped ^ "]" else stripped in

  { host = stripped; authority = header; port; path; tls }

(* Connect, under ONE deadline across every address the name resolves to.

   A name commonly resolves to several - a dual-stack host answers with both
   an A and an AAAA - and giving each the full ten seconds would make the
   real bound ten seconds times however many addresses the name cares to
   return, which is not a bound at all when the name is the attacker's.
   Each attempt gets what is left of the one deadline. *)
let connectall (addrs : Unix.sockaddr list) (budget : float) : Unix.file_descr =
  let started = Unix.gettimeofday () in
  let last = ref "no address" in

  let rec attempt = function
    | [] -> failwith !last
    | addr :: rest ->
      let left = budget -. (Unix.gettimeofday () -. started) in
      if left <= 0.0 then failwith !last
      else begin
        let domain = Unix.domain_of_sockaddr addr in
        let fd = Unix.socket domain Unix.SOCK_STREAM 0 in
        match
          Unix.set_nonblock fd;
          (try Unix.connect fd addr with
          | Unix.Unix_error ((Unix.EINPROGRESS | Unix.EWOULDBLOCK | Unix.EAGAIN), _, _) -> ());
          let _, writable, _ = Unix.select [] [ fd ] [] left in
          if [] = writable then failwith "timed out";
          (match Unix.getsockopt_error fd with
          | Some err -> raise (Unix.Unix_error (err, "connect", ""))
          | None -> ());
          Unix.clear_nonblock fd
        with
        | () -> fd
        | exception Unix.Unix_error (err, _, _) ->
          (try Unix.close fd with _ -> ());
          last := Unix.error_message err;
          attempt rest
        | exception Failure why ->
          (try Unix.close fd with _ -> ());
          last := why;
          attempt rest
      end
  in

  attempt addrs

let connect (target : target) (url : string) : Unix.file_descr =
  let addrs =
    try
      List.map
        (fun (info : Unix.addr_info) -> info.Unix.ai_addr)
        (Unix.getaddrinfo target.host (string_of_int target.port)
           [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ])
    with Unix.Unix_error (err, _, _) -> unreachable url (Unix.error_message err)
  in

  if [] = addrs then unreachable url "no address";

  let fd = try connectall addrs timeout with Failure why -> unreachable url why in

  (* A write blocks too, once the peer's receive window fills and it stops
     reading, so both directions are bounded. *)
  (try
     Unix.setsockopt_float fd Unix.SO_RCVTIMEO timeout;
     Unix.setsockopt_float fd Unix.SO_SNDTIMEO timeout
   with Unix.Unix_error _ -> ());

  fd

(* Whatever the exchange runs over: a plain socket, or a TLS session on one. *)
type channel = Plain of Unix.file_descr | Secure of Tls.conn * Unix.file_descr

let chanwrite (chan : channel) (text : string) : int -> int -> int =
 fun ofs len ->
  match chan with
  | Plain fd -> Unix.write_substring fd text ofs len
  | Secure (conn, _) -> Tls.write conn text ofs len

let chanread (chan : channel) (buf : Bytes.t) (ofs : int) (len : int) : int =
  match chan with
  | Plain fd -> Unix.read fd buf ofs len
  | Secure (conn, _) -> Tls.read conn buf ofs len

let chanclose (chan : channel) : unit =
  match chan with
  | Plain fd -> ( try Unix.close fd with _ -> ())
  | Secure (conn, fd) ->
    (try Tls.close conn with _ -> ());
    (try Unix.close fd with _ -> ())

let writeall (chan : channel) (text : string) (url : string) : unit =
  let len = String.length text in
  let at = ref 0 in
  while !at < len do
    match chanwrite chan text !at (len - !at) with
    | 0 -> unreachable url "connection closed while writing"
    | wrote -> at := !at + wrote
    | exception Unix.Unix_error (err, _, _) -> unreachable url (Unix.error_message err)
    | exception Failure why -> unreachable url why
  done

(* The offset of `needle` in `hay`, if it is there. *)
let findbytes (hay : string) (needle : string) : int option =
  let hlen = String.length hay and nlen = String.length needle in
  let rec walk index =
    if index + nlen > hlen then None
    else if String.sub hay index nlen = needle then Some index
    else walk (index + 1)
  in
  walk 0

(* Join a chunked body back together.

   Each chunk is a hex length, CRLF, that many bytes, CRLF. A zero length
   ends the body; any trailer after it is ignored.

   Bytes, not characters: a chunk length counts bytes and a boundary may
   fall inside a multibyte character, so a secret with any non-ASCII
   character in it would otherwise be cut in half. *)
let dechunk (raw : string) : string option =
  let out = Buffer.create (String.length raw) in
  let len = String.length raw in

  let rec walk at =
    match
      let rec find index =
        if index + 2 > len then None
        else if String.sub raw index 2 = "\r\n" then Some index
        else find (index + 1)
      in
      find at
    with
    | None -> None
    | Some mark ->
      let header = String.sub raw at (mark - at) in
      let head = match String.index_opt header ';' with
        | None -> header
        | Some at -> String.sub header 0 at
      in
      (match int_of_string_opt ("0x" ^ trim head) with
      | None -> None
      | Some 0 -> Some (Buffer.contents out)
      | Some size ->
        let body = mark + 2 in
        if body + size > len then None
        else begin
          Buffer.add_string out (String.sub raw body size);
          walk (body + size + 2)
        end)
  in

  walk 0

(* One HTTP exchange: any method, a set of headers, an optional body. A
   non-2xx status is answered, not raised: a 404 from a vault means "no such
   secret", which is a miss rather than a failure. *)
let request (meth : string) (url : string) (headers : (string * string) list)
    (body : string option) : response =
  let target = split url in
  let fd = connect target url in

  let chan =
    if target.tls then
      match Tls.connect fd target.host with
      | conn -> Secure (conn, fd)
      | exception Failure why ->
        (try Unix.close fd with _ -> ());
        unreachable url why
    else Plain fd
  in

  let finish () = chanclose chan in

  match
    (* A default port stays implicit in the Host header, the way a URL
       normalises it: a SigV4 signature covers `host`, and `Host: x:443` is
       not what was signed. *)
    let hostheader =
      if (target.tls && 443 = target.port) || ((not target.tls) && 80 = target.port) then
        target.authority
      else target.authority ^ ":" ^ string_of_int target.port
    in

    let out = Buffer.create 512 in
    Buffer.add_string out (meth ^ " " ^ target.path ^ " HTTP/1.1\r\n");
    Buffer.add_string out ("Host: " ^ hostheader ^ "\r\n");
    Buffer.add_string out "Accept: application/json\r\n";
    Buffer.add_string out "Connection: close\r\n";
    List.iter (fun (name, value) -> Buffer.add_string out (name ^ ": " ^ value ^ "\r\n")) headers;
    (match body with
    | Some text -> Buffer.add_string out ("Content-Length: " ^ string_of_int (String.length text) ^ "\r\n")
    | None -> ());
    Buffer.add_string out "\r\n";
    (match body with Some text -> Buffer.add_string out text | None -> ());

    writeall chan (Buffer.contents out) url;

    (* Bounded, not read-to-end: an endless body would otherwise be
       accumulated in memory until the deadline, which on a loopback or
       datacentre link is gigabytes. One byte over the bound is enough to
       know it was exceeded, and an endless body is a store that could not
       answer - so this is an error, never a miss. *)
    let held = Buffer.create 8192 in
    let chunk = Bytes.create 65536 in
    let reading = ref true in

    while !reading do
      if Buffer.length held > maxbody then reading := false
      else
        match chanread chan chunk 0 65536 with
        | 0 -> reading := false
        | got -> Buffer.add_subbytes held chunk 0 got
        | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
          unreachable url "timed out"
        | exception Unix.Unix_error (err, _, _) -> unreachable url (Unix.error_message err)
        | exception Failure why -> unreachable url why
    done;

    if Buffer.length held > maxbody then fail ("sekreto: oversized response from " ^ bare url);

    let raw = Buffer.contents held in

    let split_at =
      match findbytes raw "\r\n\r\n" with
      | Some at -> at
      | None -> fail ("sekreto: malformed response from " ^ bare url)
    in

    (* Headers are ASCII; the body is not necessarily, so it stays bytes
       until every length-counted slice has been taken. *)
    let head = String.sub raw 0 split_at in
    let rawbody = String.sub raw (split_at + 4) (String.length raw - split_at - 4) in

    let lines = String.split_on_char '\n' head in
    let statusline = match lines with first :: _ -> first | [] -> "" in

    let status =
      match String.split_on_char ' ' (String.trim statusline) with
      | _ :: code :: _ -> ( match int_of_string_opt code with Some value -> value | None -> -1)
      | _ -> -1
    in

    if -1 = status then fail ("sekreto: malformed response from " ^ bare url);

    let chunked =
      List.exists
        (fun line ->
          match String.index_opt line ':' with
          | None -> false
          | Some at ->
            let name = String.lowercase_ascii (trim (String.sub line 0 at)) in
            let value = String.lowercase_ascii (String.sub line (at + 1) (String.length line - at - 1)) in
            "transfer-encoding" = name
            && None <> findsub value "chunked")
        (match lines with _ :: rest -> rest | [] -> [])
    in

    let text =
      if chunked then
        match dechunk rawbody with
        | Some value -> value
        | None -> fail ("sekreto: malformed response from " ^ bare url)
      else rawbody
    in

    { status; body = text }
  with
  | answer ->
    finish ();
    answer
  | exception err ->
    finish ();
    raise err

(* Decode standard base64: an AWS SecretBinary, a GCP secret payload.

   STRICT, deliberately. A lenient decoder skips bytes outside the alphabet
   and hands back plausible-looking bytes for a corrupted payload - which
   then get returned as the secret. Whitespace is stripped first, because
   the canonical function accepts embedded newlines; everything else outside
   `A-Za-z0-9+/` with at most two trailing `=`, and any length that is not a
   multiple of four, is refused. A refusal is an error, never a miss. *)
let unbase64 (text : string) : string option =
  let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" in

  let packed = Buffer.create (String.length text) in
  String.iter
    (fun ch -> match ch with ' ' | '\t' | '\n' | '\r' | '\012' -> () | _ -> Buffer.add_char packed ch)
    text;
  let body = Buffer.contents packed in
  let len = String.length body in

  let pad =
    if len >= 2 && '=' = body.[len - 1] && '=' = body.[len - 2] then 2
    else if len >= 1 && '=' = body.[len - 1] then 1
    else 0
  in
  let core = String.sub body 0 (len - pad) in

  if 0 <> len mod 4 then None
  else if not (String.for_all (fun ch -> String.contains alphabet ch) core) then None
  else begin
    let out = Buffer.create len in
    let acc = ref 0 and bits = ref 0 in

    String.iter
      (fun ch ->
        acc := (!acc lsl 6) lor String.index alphabet ch;
        bits := !bits + 6;
        if 8 <= !bits then begin
          bits := !bits - 8;
          Buffer.add_char out (Char.chr ((!acc lsr !bits) land 0xff))
        end)
      core;

    Some (Buffer.contents out)
  end
