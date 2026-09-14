(* VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ocaml/plugins/sigv4.ml) *)
(* Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* AWS Signature Version 4, hand-rolled.

   The AWS providers need exactly one thing from the AWS SDK - request
   signing - and taking the SDK for it would break the no-dependency rule
   that keeps the ports honest. SigV4 is a stable, published algorithm built
   from HMAC-SHA256, which plugins/crypto.ml carries.

   `sigv4` is pure: the caller passes the timestamp, so the same input
   yields the same signature everywhere. That is what lets the shared spec
   carry known-answer cases that all ports must reproduce bit for bit, and
   lets the integration mock recompute the signature server-side. Nothing
   here samples the clock.

   A port of typescript/src/Sigv4.ts, which is canonical. *)

open Secret

(* One request to sign - the same declarative shape the shared spec uses.
   `datetime` is `YYYYMMDDTHHMMSSZ`, and it is the caller's. *)
type signing = {
  smethod : string;
  url : string;
  service : string;
  region : string;
  keyid : string;
  secret : string;
  datetime : string;
  headers : (string * string) list;
  body : string;
  session : string;
}

let nosigning =
  {
    smethod = "";
    url = "";
    service = "";
    region = "";
    keyid = "";
    secret = "";
    datetime = "";
    headers = [];
    body = "";
    session = "";
  }

(* RFC 3986 escaping, which is stricter than the usual URL encoder: AWS
   wants everything but the unreserved set escaped, byte by byte over UTF-8,
   with UPPERCASE hex. `!'()*` are escaped here and are not by the encoders
   most standard libraries offer. *)
let uriescape (text : string) : string =
  let out = Buffer.create (String.length text) in
  String.iter
    (fun ch ->
      let code = Char.code ch in
      if
        ('A' <= ch && ch <= 'Z')
        || ('a' <= ch && ch <= 'z')
        || ('0' <= ch && ch <= '9')
        || '-' = ch || '_' = ch || '.' = ch || '~' = ch
      then Buffer.add_char out ch
      else Buffer.add_string out (Printf.sprintf "%%%02X" code))
    text;
  Buffer.contents out

let hexvalue (ch : char) : int option =
  match ch with
  | '0' .. '9' -> Some (Char.code ch - Char.code '0')
  | 'a' .. 'f' -> Some (Char.code ch - Char.code 'a' + 10)
  | 'A' .. 'F' -> Some (Char.code ch - Char.code 'A' + 10)
  | _ -> None

(* Percent-decode, and nothing else: `+` stays `+`, as on the wire, and a
   malformed escape is kept literally. *)
let uridecode (text : string) : string =
  let out = Buffer.create (String.length text) in
  let len = String.length text in
  let index = ref 0 in

  while !index < len do
    let taken = ref false in

    if '%' = text.[!index] && !index + 2 < len then begin
      match (hexvalue text.[!index + 1], hexvalue text.[!index + 2]) with
      | Some high, Some low ->
        Buffer.add_char out (Char.chr ((high * 16) + low));
        index := !index + 3;
        taken := true
      | _ -> ()
    end;

    if not !taken then begin
      Buffer.add_char out text.[!index];
      incr index
    end
  done;

  Buffer.contents out

(* Split a query into pairs on `&`, then each on its FIRST `=`. A pair with
   no `=` keeps an empty value and is still emitted with one. *)
let canonicalquery (query : string) : string =
  if "" = query then ""
  else
    let pairs =
      List.map
        (fun pair ->
          match String.index_opt pair '=' with
          | None -> (uriescape (uridecode pair), "")
          | Some eq ->
            ( uriescape (uridecode (String.sub pair 0 eq)),
              uriescape (uridecode (String.sub pair (eq + 1) (String.length pair - eq - 1))) ))
        (String.split_on_char '&' query)
    in
    let sorted =
      List.stable_sort
        (fun (lk, lv) (rk, rv) -> if lk = rk then compare lv rv else compare lk rk)
        pairs
    in
    String.concat "&" (List.map (fun (key, value) -> key ^ "=" ^ value) sorted)

(* The url, hand-split into the four parts signing needs.

   Hand-split, not handed to a URL type: twelve URL parsers disagree about
   malformed input, and the signature covers `host` and the raw path, so a
   parser that normalises either of them signs something the server will not
   recompute. *)
type parts = { scheme : string; authority : string; path : string; query : string }

let urlparts (url : string) : parts =
  match findsub url "://" with
  | None -> { scheme = ""; authority = ""; path = url; query = "" }
  | Some mark ->
    let scheme = String.sub url 0 mark in
    let rest = String.sub url (mark + 3) (String.length url - mark - 3) in
    let stop = match splitfirst rest "/?#" with Some at -> at | None -> String.length rest in
    let authority = String.sub rest 0 stop in
    let tail = String.sub rest stop (String.length rest - stop) in
    let path, query =
      match String.index_opt tail '?' with
      | None -> (tail, "")
      | Some at -> (String.sub tail 0 at, String.sub tail (at + 1) (String.length tail - at - 1))
    in
    let path = match String.index_opt path '#' with None -> path | Some at -> String.sub path 0 at in
    { scheme; authority; path = (if "" = path then "/" else path); query }

(* The `host` header as the canonical form wants it: the hostname
   lowercased, any userinfo stripped, and the port appended ONLY when it is
   not the scheme's default - `:443` on https is not what a URL normalises
   to and not what the service recomputes. *)
let hostheader (scheme : string) (authority : string) : string =
  let bare =
    match String.rindex_opt authority '@' with
    | None -> authority
    | Some at -> String.sub authority (at + 1) (String.length authority - at - 1)
  in

  let host, port =
    if String.length bare > 0 && '[' = bare.[0] then
      match String.index_opt bare ']' with
      | None -> (bare, "")
      | Some close ->
        let head = String.sub bare 0 (close + 1) in
        let tail = String.sub bare (close + 1) (String.length bare - close - 1) in
        (head, if String.length tail > 1 && ':' = tail.[0] then String.sub tail 1 (String.length tail - 1) else "")
    else
      match String.rindex_opt bare ':' with
      | None -> (bare, "")
      | Some at ->
        ( String.sub bare 0 at,
          String.sub bare (at + 1) (String.length bare - at - 1) )
  in

  let host = String.lowercase_ascii host in
  let default = if "https" = scheme then "443" else "80" in

  if "" = port || port = default then host else host ^ ":" ^ port

(* Collapse every internal whitespace run - spaces AND tabs - to one space,
   after trimming. AWS folds header values before signing, so `a  b\tc`
   must sign as `a b c` or the service refuses the request. *)
let foldvalue (value : string) : string =
  let trimmed = trim value in
  let out = Buffer.create (String.length trimmed) in
  let inrun = ref false in
  String.iter
    (fun ch ->
      if ' ' = ch || '\t' = ch || '\n' = ch || '\r' = ch then inrun := true
      else begin
        if !inrun then Buffer.add_char out ' ';
        inrun := false;
        Buffer.add_char out ch
      end)
    trimmed;
  Buffer.contents out

(* Sign one request. Answers the headers to attach: authorization,
   x-amz-date, and x-amz-security-token when a session token was given, in
   that order - the spec compares the result as a whole JSON object, so the
   order is contract. *)
let sigv4 (input : signing) : (string * string) list =
  let parts = urlparts input.url in
  let date = String.sub input.datetime 0 (min 8 (String.length input.datetime)) in

  (* The caller's headers first, then host, x-amz-date and the session
     token, so that those three win over anything the caller passed. *)
  let headers = ref [] in
  List.iter
    (fun (key, value) -> headers := assocset !headers (String.lowercase_ascii key) (foldvalue value))
    input.headers;
  headers := assocset !headers "host" (hostheader parts.scheme parts.authority);
  headers := assocset !headers "x-amz-date" input.datetime;
  if "" <> input.session then headers := assocset !headers "x-amz-security-token" input.session;

  let sorted = List.stable_sort (fun (l, _) (r, _) -> compare l r) !headers in

  let canonicalheaders =
    String.concat "" (List.map (fun (key, value) -> key ^ ":" ^ value ^ "\n") sorted)
  in
  let signedheaders = String.concat ";" (List.map fst sorted) in

  let canonicalrequest =
    String.concat "\n"
      [
        String.uppercase_ascii input.smethod;
        parts.path;
        canonicalquery parts.query;
        canonicalheaders;
        signedheaders;
        Crypto.sha256hex input.body;
      ]
  in

  let scope = date ^ "/" ^ input.region ^ "/" ^ input.service ^ "/aws4_request" in

  let stringtosign =
    String.concat "\n"
      [ "AWS4-HMAC-SHA256"; input.datetime; scope; Crypto.sha256hex canonicalrequest ]
  in

  let kdate = Crypto.hmac ("AWS4" ^ input.secret) date in
  let kregion = Crypto.hmac kdate input.region in
  let kservice = Crypto.hmac kregion input.service in
  let ksigning = Crypto.hmac kservice "aws4_request" in
  let signature = Crypto.hex (Crypto.hmac ksigning stringtosign) in

  let out =
    [
      ( "authorization",
        "AWS4-HMAC-SHA256 Credential=" ^ input.keyid ^ "/" ^ scope ^ ", SignedHeaders="
        ^ signedheaders ^ ", Signature=" ^ signature );
      ("x-amz-date", input.datetime);
    ]
  in

  if "" = input.session then out else out @ [ ("x-amz-security-token", input.session) ]
