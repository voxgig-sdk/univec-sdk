-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lean/plugins/SekretoPlugins/Httpjson.lean)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/-
THE SHARED PLUGIN SUPPORT: one HTTP round-trip, and the handful of
helpers that every store which dials one needs.

This module and ffi/sekreto_curl.c are the whole of this port's contact
with the network, and they are UNDER `plugins/`: a chain of the four
built-in kinds links neither, which is the point of the split. Everything
above them - JSON, the ten plugin kinds, SigV4 - is in-tree Lean, and
everything below them is libcurl.

What the binding guarantees, and why, is written out in
ffi/sekreto_curl.c: chain verification against the system store,
HOSTNAME verification (the separate half), SNI, and SEKRETO_CA_BUNDLE as
an ADDITIVE source of extra roots. What this file adds is the contract
the rest of the library depends on: a 10 s bound, an 8 MiB cap, no
redirects, no proxies, HTTP/1.1 - and the rule that a store that could
not answer RAISES rather than missing.

Base64 decoding, percent-escaping and token renewal are here for the same
reason they are in the rust port's `httpjson` crate: several plugins need
them, no plugin should reach into another, and the core needs none of
them.

A port of typescript/plugins/httpjson.ts, which is canonical.
-/

import Sekreto.Text
import Sekreto.Json
import Sekreto.Core
import Sekreto.Provider
import Sekreto.Addr

namespace Sekreto

/-- Drop one trailing `/` from a base address. -/
def trimslash (text : String) : String := dropsuffix text "/"

/-- RFC 3986 escaping, which is stricter than the usual URL encoder: AWS
wants everything but the unreserved set escaped, byte by byte over UTF-8,
with UPPERCASE hex. `!'()*` are escaped too - that is the gap against
JavaScript's `encodeURIComponent`. Every store that puts a project name
or a scope into a query string uses it too, so it lives here rather than
in the aws plugin that needs it strictest. -/
def uriescape (text : String) : String :=
  text.toUTF8.toList.foldl (fun out byte =>
    let ch := Char.ofNat byte.toNat
    if ('A' ≤ ch && ch ≤ 'Z') || ('a' ≤ ch && ch ≤ 'z') || ('0' ≤ ch && ch ≤ '9') ||
        '-' == ch || '_' == ch || '.' == ch || '~' == ch then
      out.push ch
    else out ++ "%" ++ hexbyteupper byte) ""

/-- The libcurl round-trip. See the framing note in ffi/sekreto_curl.c:
one tag byte, four status bytes, then the payload.

`@&` on every string: the arguments are BORROWED, so the C side reads
them and does not release them. Without it Lean would hand ownership
over and the binding would have to drop each one by hand. -/
@[extern "sekreto_curl_fetch"]
opaque curlfetch (method : @& String) (url : @& String) (headers : @& String)
    (body : @& String) (hasbody : Bool) (cabundle : @& String) : IO ByteArray

/-- One JSON round-trip's result: the status, and the parsed body. -/
structure Answer where
  status : Nat
  body : Option Json
  deriving Inhabited

/-- A header value with CR and LF removed.

A vault token arrives from configuration and goes out in a header. One
containing a newline would end the header and start another, which is
request splitting; the two characters have no legitimate place in any
value this library sends. -/
private def headervalue (value : String) : String :=
  String.mk (value.toList.filter (fun ch => '\r' != ch && '\n' != ch))

/-- Extra trust roots, from the one variable every port in this
repository agrees on. Empty means unset, and an unreadable or unusable
file adds nothing and raises nothing - it fails OPEN, silently, exactly
as rust/src/http.rs does. -/
private def cabundle : IO String := do
  return ((← IO.getEnv "SEKRETO_CA_BUNDLE").getD "")

/-- One JSON round-trip.

Network failure is ALWAYS an error - an unreachable store is a store
that could not answer, and returning a miss there would fall through to
a weaker store on an attacker's cue. So is an oversized body, and so is
a 200 whose body does not parse. A non-200 with an unreadable body is
fine: error statuses are decided on status alone. -/
def fetchjson (method url : String) (headers : Pairs String := [])
    (body : Option String := none) : IO Answer := do
  let lines := String.intercalate "\n"
    (headers.map (fun kv => kv.1 ++ ": " ++ headervalue kv.2))

  let raw ← curlfetch method url lines (body.getD "") body.isSome (← cabundle)

  if 5 > raw.size then
    fail ("sekreto: cannot reach " ++ bareurl url ++ ": no answer")

  let tag := raw.get! 0
  let status :=
    (raw.get! 1).toNat * 16777216 + (raw.get! 2).toNat * 65536 +
    (raw.get! 3).toNat * 256 + (raw.get! 4).toNat
  let payload := raw.extract 5 raw.size

  if 'Z'.toNat.toUInt8 == tag then
    fail ("sekreto: oversized response from " ++ bareurl url)

  if 'E'.toNat.toUInt8 == tag then
    let why := (String.fromUTF8? payload).getD "transport failure"
    fail ("sekreto: cannot reach " ++ bareurl url ++ ": " ++ why)

  -- A body that is not UTF-8 cannot be JSON either, so it takes the same
  -- path a body that is text but not JSON takes.
  let parsed := (String.fromUTF8? payload).bind Json.parse

  if 200 == status && parsed.isNone then
    fail ("sekreto: malformed response from " ++ bareurl url)

  return { status := status, body := parsed }

private def B64ALPHABET : String :=
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

private def b64value (ch : Char) : Option Nat :=
  indexOfChar B64ALPHABET ch

/-- Decode standard (not URL-safe) base64, STRICTLY.

Whitespace is stripped first - the callers accept payloads wrapped across
lines - and then anything outside the alphabet, a run of more than two
`=`, or a length that is not a multiple of four is REFUSED. A lenient
decoder silently skips the bytes it does not recognise and hands back
plausible-looking bytes for a corrupted payload, which then get returned
as the secret; refusing is the only safe answer, and every caller turns a
refusal into an error rather than a miss. -/
def unbase64 (text : String) : Option ByteArray := Id.run do
  let chars := text.toList.filter (fun ch => !ch.isWhitespace)

  let body := chars.takeWhile (fun ch => '=' != ch)
  let tail := chars.drop body.length

  if tail.length > 2 || !tail.all (fun ch => '=' == ch) then return none
  if 0 != chars.length % 4 then return none
  if chars.isEmpty then return some ByteArray.empty

  let mut out := ByteArray.empty
  let mut acc : Nat := 0
  let mut bits : Nat := 0

  for ch in body do
    match b64value ch with
    | none => return none
    | some value =>
      acc := acc * 64 + value
      bits := bits + 6
      if 8 ≤ bits then
        out := out.push (UInt8.ofNat ((acc >>> (bits - 8)) % 256))
        bits := bits - 8
        acc := acc % (2 ^ bits)

  return some out

/-- Decode base64 to text. Nothing when the payload is not strict base64,
or is not UTF-8 once decoded. -/
def unbase64text (text : String) : Option String :=
  (unbase64 text).bind String.fromUTF8?

/-- An expiry in seconds, from a JSON number OR a numeric string: Azure
IMDS sends `expires_in` as `"3599"`, and a port that reads only numbers
renews a managed-identity token every request. Anything else is zero,
which means never renew. -/
def expiryof (value : Option Json) : Float :=
  match value with
  | some (.num held) => held
  | some (.str held) => ((Json.parse held).bind Json.asnum).getD 0.0
  | _ => 0.0

/-- Never renew. -/
def NEVER : Nat := 0xffffffffffffffff

/-- When a logged-in token must be renewed, from its expiry in seconds:
now + max(seconds - 60, 1). A missing or zero expiry means never renew,
so a CONFIGURED token is kept for the life of the process.

Monotonic milliseconds, not the wall clock: a machine whose clock steps
backwards must not stop renewing. -/
def renewat (seconds : Float) : IO Nat := do
  if seconds.isNaN || 0.0 ≥ seconds then return NEVER
  let ahead := if seconds - 60.0 < 1.0 then 1.0 else seconds - 60.0
  return (← IO.monoMsNow) + (ahead * 1000.0).toUInt64.toNat

end Sekreto
