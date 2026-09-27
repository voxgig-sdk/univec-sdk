-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lean/plugins/SekretoPlugins/Sigv4.lean)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/-
AWS Signature Version 4, hand-rolled.

The AWS providers need exactly one thing from the AWS SDK - request
signing - and taking the SDK for it would break the no-dependency rule
that keeps the ports honest. SigV4 is a stable, published algorithm built
from HMAC-SHA256, which SekretoPlugins.Crypto supplies.

`sigv4` is pure: the caller passes the timestamp, so the same input
yields the same signature everywhere. That is what lets the shared spec
carry known-answer cases that all ports must reproduce bit for bit, and
lets the integration mock recompute the signature server-side. Nothing
here samples the clock.

A port of typescript/plugins/sigv4.ts, which is canonical.
-/

import Sekreto.Text
import Sekreto.Json
import SekretoPlugins.Crypto
import SekretoPlugins.Httpjson

namespace Sekreto

/-- One request to sign - the same declarative shape the shared spec
uses. `datetime` is `YYYYMMDDTHHMMSSZ`, and it is the caller's. -/
structure Signing where
  method : String
  url : String
  service : String
  region : String
  keyid : String
  secret : String
  datetime : String
  headers : Pairs String := []
  body : String := ""
  session : String := ""
  deriving Inhabited

/-- Percent-decode, and nothing else: `+` stays `+`, as it is on the
wire, and a malformed `%` escape is kept literally, the way a browser
would. -/
def uridecode (text : String) : String :=
  let rec scan (chars : List Char) (out : ByteArray) : ByteArray :=
    match chars with
    | [] => out
    | '%' :: high :: low :: rest =>
      match hexdigit high, hexdigit low with
      | some hi, some lo => scan rest (out.push (UInt8.ofNat (hi * 16 + lo)))
      | _, _ => scan (high :: low :: rest) (out ++ "%".toUTF8)
    | ch :: rest => scan rest (out ++ (String.singleton ch).toUTF8)
  let bytes := scan text.toList ByteArray.empty
  (String.fromUTF8? bytes).getD text

/-- The canonical query string: each pair RFC 3986-escaped, sorted by
escaped key then escaped value. `?b=2&a=1` signs as `a=1&b=2`. -/
def canonicalquery (query : String) : String :=
  if query.isEmpty then ""
  else
    let pairs := (query.splitOn "&").map (fun pair =>
      match indexOfChar pair '=' with
      | none => (uriescape (uridecode pair), "")
      | some eq =>
        (uriescape (uridecode (pair.take eq).toString),
         uriescape (uridecode (pair.drop (eq + 1)).toString)))
    let ordered := pairs.mergeSort (fun left right =>
      left.1 < right.1 || (left.1 == right.1 && left.2 ≤ right.2))
    String.intercalate "&" (ordered.map (fun pair => pair.1 ++ "=" ++ pair.2))

/-- The three parts of a URL that signing needs: the `host` header, the
raw already-encoded path, and the raw query.

Hand-split, and never through a platform URL type. The `host` header is
what the WHATWG `URL.host` would be - hostname lowercased, userinfo
stripped, and the port appended ONLY when it is not the scheme's default,
because `Host: example.com:443` is not what a signature covers. -/
def splitsigurl (url : String) : String × String × String :=
  let scheme :=
    if url.startsWith "https://" then "https://"
    else if url.startsWith "http://" then "http://"
    else ""
  let rest := (url.drop scheme.length).toString
  let stop := (indexWhere rest (fun ch => '/' == ch || '?' == ch || '#' == ch)).getD rest.length
  let authority := (rest.take stop).toString
  let tail := (rest.drop stop).toString

  let hostport := match lastIndexOfChar authority '@' with
    | some mark => (authority.drop (mark + 1)).toString
    | none => authority

  let (bare, port) :=
    if hostport.startsWith "[" then
      match indexOfChar hostport ']' with
      | some close =>
        let after := (hostport.drop (close + 1)).toString
        ((hostport.take (close + 1)).toString,
         if after.startsWith ":" then (after.drop 1).toString else "")
      | none => (hostport, "")
    else
      match indexOfChar hostport ':' with
      | some mark => ((hostport.take mark).toString, (hostport.drop (mark + 1)).toString)
      | none => (hostport, "")

  let defaultport := if "https://" == scheme then "443" else "80"
  let host := asciilower bare ++ (if port.isEmpty || port == defaultport then "" else ":" ++ port)

  let hashless := match indexOfChar tail '#' with
    | some mark => (tail.take mark).toString
    | none => tail
  let (path, query) := match indexOfChar hashless '?' with
    | some mark => ((hashless.take mark).toString, (hashless.drop (mark + 1)).toString)
    | none => (hashless, "")

  (host, if path.isEmpty then "/" else path, query)

/-- Trim, then collapse every internal run of spaces and tabs to one
space. AWS folds sequential whitespace before signing, so `a  b\tc` must
sign as `a b c` or the service refuses the request. -/
private def foldvalue (value : String) : String :=
  let rec scan (chars : List Char) (out : String) (gap : Bool) : String :=
    match chars with
    | [] => out
    | ch :: rest =>
      if ' ' == ch || '\t' == ch then scan rest out true
      else scan rest ((if gap && !out.isEmpty then out.push ' ' else out).push ch) false
  scan value.trim.toList "" false

/-- Sign one request. Answers the headers to attach: `authorization`,
`x-amz-date`, and `x-amz-security-token` when a session token was given,
in that order - the spec compares the result as a JSON object, and
callers print it field by field. -/
def sigv4 (input : Signing) : Pairs String :=
  let (host, path, query) := splitsigurl input.url
  let date := (input.datetime.take 8).toString

  -- Every header that will be signed: the caller's extras first, then
  -- host and x-amz-date (and the session token when present) OVER them,
  -- then sorted by name, ASCII ascending, which is the canonical order.
  let folded := input.headers.foldl
    (fun out kv => Pairs.put out (asciilower kv.1) (foldvalue kv.2)) ([] : Pairs String)
  let withhost := Pairs.put (Pairs.put folded "host" host) "x-amz-date" input.datetime
  let all := if input.session.isEmpty then withhost
    else Pairs.put withhost "x-amz-security-token" input.session
  let headers := all.mergeSort (fun left right => left.1 ≤ right.1)

  let canonicalheaders :=
    headers.foldl (fun out kv => out ++ kv.1 ++ ":" ++ kv.2 ++ "\n") ""
  let signedheaders := String.intercalate ";" (Pairs.keys headers)

  -- Six lines. `canonicalheaders` already ends in a newline, which is
  -- what produces the blank line before `signedheaders`.
  let canonicalrequest := String.intercalate "\n" [
    asciiupper input.method,
    path,
    canonicalquery query,
    canonicalheaders,
    signedheaders,
    sha256hex input.body]

  let scope := date ++ "/" ++ input.region ++ "/" ++ input.service ++ "/aws4_request"

  let stringtosign := String.intercalate "\n" [
    "AWS4-HMAC-SHA256",
    input.datetime,
    scope,
    sha256hex canonicalrequest]

  let kdate := hmac ("AWS4" ++ input.secret).toUTF8 date
  let kregion := hmac kdate input.region
  let kservice := hmac kregion input.service
  let ksigning := hmac kservice "aws4_request"
  let signature := hexlower (hmac ksigning stringtosign)

  let out : Pairs String := [
    ("authorization",
      "AWS4-HMAC-SHA256 Credential=" ++ input.keyid ++ "/" ++ scope ++
      ", SignedHeaders=" ++ signedheaders ++
      ", Signature=" ++ signature),
    ("x-amz-date", input.datetime)]

  if input.session.isEmpty then out else out ++ [("x-amz-security-token", input.session)]

end Sekreto
