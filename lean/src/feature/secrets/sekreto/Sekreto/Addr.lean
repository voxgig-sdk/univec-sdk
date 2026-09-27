-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lean/src/Sekreto/Addr.lean)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/-
Address checking: CORE, never a plugin.

Two pure functions over a string, called by every network kind before it
opens anything. Hand-parsed, and never with a platform URL type: a dozen
parsers disagree about malformed input - where userinfo ends, whether
`0177.0.0.1` is loopback, what an unclosed bracket means - and a check
that answers differently in different ports is not a check.

The rule this parse obeys, and the reason it can be trusted: it is never
MORE PERMISSIVE than the HTTP client that will dial the address. It ends
the authority at `/`, `?` or `#` only, so a client that also breaks on
`\` (WHATWG does) can only ever see a SHORTER host than this does. It
refuses userinfo outright rather than locating its end. It compares the
host literally, so a numeric form no parser here agrees on is refused
rather than guessed at.
-/

import Sekreto.Text

namespace Sekreto

/-- An address with any userinfo replaced by `[redacted]`, for messages.

Every refusal below names the address it refused, and one of them fires
precisely because the address carries a credential - so printing it
verbatim would write the password to stderr and into the logs. It cannot
be cleaned up afterwards either: that password was never resolved as a
secret, so `redact` has never seen it and never will. -/
def safeaddr (addr : String) : String :=
  match indexOfText addr "://" with
  | none => addr
  | some mark =>
    let rest := (addr.drop (mark + 3)).toString
    let stop := (indexWhere rest (fun ch => '/' == ch || '?' == ch || '#' == ch)).getD rest.length
    let authority := (rest.take stop).toString
    match lastIndexOfChar authority '@' with
    | none => addr
    | some at' => (addr.take (mark + 3)).toString ++ "[redacted]" ++ (addr.drop (mark + 3 + at')).toString

/-- The four literal spellings of the local machine. Nothing is
normalised: `0177.0.0.1`, `2130706433`, `127.0.0.2` and
`[::ffff:127.0.0.1]` are all refused rather than guessed at. -/
private def LOOPBACK : List String := ["localhost", "127.0.0.1", "::1", "[::1]"]

/-- Refuse to send a secret-bearing credential in the clear.

A vault API is HTTPS in any real deployment; plaintext is a dev-mode
convenience. Sending a token over http to anything but the local machine
puts both the token and the secret it fetches on the wire for anyone on
the path, so sekreto will not do it. Loopback stays allowed: that is
`vault server -dev`, `boru vault serve`, and this repo's own test
harness. -/
def checkaddr (addr : String) : Except String Unit := do
  let scheme :=
    if addr.startsWith "https://" then "https://"
    else if addr.startsWith "http://" then "http://"
    else ""

  if scheme.isEmpty then
    throw ("sekreto: not an http(s) address: " ++ safeaddr addr)

  let rest := (addr.drop scheme.length).toString
  let stop := (indexWhere rest (fun ch => '/' == ch || '?' == ch || '#' == ch)).getD rest.length
  let authority := (rest.take stop).toString

  -- Userinfo is refused outright rather than parsed around, and on https
  -- as well as http. No store this library speaks authenticates by
  -- userinfo, so an address carrying one is a mistake at best. At worst
  -- it is the attack this whole function exists to stop:
  -- `http://localhost:8200@evil.example.com/` is a request to
  -- evil.example.com that reads, to anything that splits the authority
  -- on ':', as loopback.
  if hasText authority "@" then
    throw ("sekreto: refusing an address with embedded credentials: " ++ safeaddr addr)

  -- An opening bracket with no closing one is not an address at all.
  if authority.startsWith "[" && !hasText authority "]" then
    throw ("sekreto: not a valid http(s) address: " ++ safeaddr addr)

  if "https://" == scheme then return ()

  -- A bracketed IPv6 literal keeps its brackets. Splitting the authority
  -- on the first colon yields `[`, which could never match the `[::1]`
  -- entry below - and so refused a legitimate local vault.
  let host := asciilower (
    if authority.startsWith "[" then
      match indexOfChar authority ']' with
      | some close => (authority.take (close + 1)).toString
      | none => authority
    else takeWhile authority (fun ch => ':' != ch))

  if !LOOPBACK.contains host then
    throw ("sekreto: refusing to send a token in plaintext to " ++ safeaddr addr ++ " (use https)")

/-- A URL without its query string, for a message that must not leak
one. -/
def bareurl (url : String) : String := takeWhile url (fun ch => '?' != ch)

end Sekreto
