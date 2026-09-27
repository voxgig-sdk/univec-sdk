-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lean/src/Sekreto/Text.lean)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/-
Small string helpers, in-tree.

Lean's `String` is UTF-8 with byte positions, and its standard library
carries no substring search, no ASCII-only case mapping guarantee for
whole strings, and no hex. Everything below is what the rest of the port
needs and nothing more: the same handful of operations every other port
reaches for in its own standard library.

`Char.toUpper` in Lean core maps `a`-`z` and leaves every other code
point alone, so `asciiupper` is locale-invariant by construction - the
Turkish-locale hazard that bites the JVM, .NET and Swift cannot arise
here.
-/

namespace Sekreto

/-- Drop `suffix` if it is there. `.` and `_` both occur inside names, so
this is spelled out rather than reached for through a pattern. -/
def dropsuffix (text suffix : String) : String :=
  if text.endsWith suffix then text.dropRight suffix.length else text

/-- Split on the literal dot, KEEPING trailing empties, so that `a.` is
two segments and not one. `String.splitOn` already keeps them. -/
def segments (name : String) : List String := name.splitOn "."

/-- Uppercase the ASCII letters and nothing else. -/
def asciiupper (text : String) : String :=
  String.mk (text.toList.map Char.toUpper)

/-- Lowercase the ASCII letters and nothing else. -/
def asciilower (text : String) : String :=
  String.mk (text.toList.map Char.toLower)

/-- Is `part` a single well-formed name segment: `[a-z0-9_]+`? -/
def namepart (part : String) : Bool :=
  !part.isEmpty && part.toList.all (fun ch =>
    ('a' ≤ ch && ch ≤ 'z') || ('0' ≤ ch && ch ≤ '9') || '_' == ch)

/-- The character index of the first character `want` accepts, or none.
Character index, not byte offset: every caller here slices with `take`
and `drop`, which count characters. -/
def indexWhere (text : String) (want : Char → Bool) : Option Nat :=
  let rec scan (chars : List Char) (pos : Nat) : Option Nat :=
    match chars with
    | [] => none
    | ch :: rest => if want ch then some pos else scan rest (pos + 1)
  scan text.toList 0

/-- The character index of the first `ch`, or none. -/
def indexOfChar (text : String) (ch : Char) : Option Nat :=
  indexWhere text (fun other => other == ch)

/-- The character index of the last `ch`, or none. -/
def lastIndexOfChar (text : String) (ch : Char) : Option Nat :=
  let rec scan (chars : List Char) (pos : Nat) (found : Option Nat) : Option Nat :=
    match chars with
    | [] => found
    | head :: rest => scan rest (pos + 1) (if head == ch then some pos else found)
  scan text.toList 0 none

/-- The leading run of characters `want` accepts. -/
def takeWhile (text : String) (want : Char → Bool) : String :=
  String.mk (text.toList.takeWhile want)

/-- Does `hay` contain `needle`? An empty needle is contained by
everything, which is what a substring test means and what `splitOn`
cannot be asked. -/
def hasText (hay needle : String) : Bool :=
  if needle.isEmpty then true else 1 != (hay.splitOn needle).length

/-- The character index at which `needle` first occurs in `hay`. -/
def indexOfText (hay needle : String) : Option Nat :=
  if needle.isEmpty then some 0
  else
    match hay.splitOn needle with
    | [] => none
    | [_] => none
    | before :: _ => some before.length

/-- Replace every occurrence of `needle` in `hay` with `swap`. An empty
needle changes nothing, rather than looping. -/
def replaceAll (hay needle swap : String) : String :=
  if needle.isEmpty then hay else hay.replace needle swap

/-- One byte as two lowercase hex digits. -/
def hexbyte (byte : UInt8) : String :=
  let digits := "0123456789abcdef".toList
  let value := byte.toNat
  String.mk [digits.getD (value / 16) '0', digits.getD (value % 16) '0']

/-- Bytes as lowercase hex. -/
def hexlower (bytes : ByteArray) : String :=
  bytes.toList.foldl (fun out byte => out ++ hexbyte byte) ""

/-- One byte as two UPPERCASE hex digits: percent-escapes, and nothing
else in this library, want them that way. -/
def hexbyteupper (byte : UInt8) : String := asciiupper (hexbyte byte)

/-- The value of one hex digit, or none. -/
def hexdigit (ch : Char) : Option Nat :=
  if '0' ≤ ch && ch ≤ '9' then some (ch.toNat - '0'.toNat)
  else if 'a' ≤ ch && ch ≤ 'f' then some (ch.toNat - 'a'.toNat + 10)
  else if 'A' ≤ ch && ch ≤ 'F' then some (ch.toNat - 'A'.toNat + 10)
  else none

/-- Render a whole number held in a `Float`, without a fractional tail. -/
def intstr (value : Float) : String :=
  let negative := value < 0.0
  let size := (if negative then -value else value).toUInt64.toNat
  (if negative && 0 != size then "-" else "") ++ toString size

/-- Render a number the way every other port does: a whole number has no
fractional tail, so a JSON `1` read back and printed stays `1`. Anything
else falls to the platform's own rendering, with the trailing zeros Lean
always prints trimmed away. -/
def numstr (value : Float) : String :=
  if value.isNaN || value.isInf then "null"
  else if value == value.floor && 9007199254740992.0 > value.abs then intstr value
  else
    let text := value.toString
    if hasText text "." then
      let trimmed := String.mk (text.toList.reverse.dropWhile (fun ch => '0' == ch)).reverse
      if trimmed.endsWith "." then trimmed ++ "0" else trimmed
    else text

/-- The first candidate that is set and non-empty, or the empty string.
"Not configured" and "configured empty" mean the same thing everywhere in
this library, so both are absent here. -/
def first (candidates : List String) : String :=
  (candidates.find? (fun value => !value.isEmpty)).getD ""

/-- What a credential field reports about itself. A derived printer would
put the Vault token, the AWS secret key and the Azure client secret into
whatever formatted it. -/
def setornot (value : String) : String := if value.isEmpty then "[unset]" else "[set]"

end Sekreto
