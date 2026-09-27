-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lean/src/Sekreto/Json.lean)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/-
Minimal JSON support for sekreto.

sekreto adds no third-party dependencies, so it carries just enough JSON
to read a vault's answer and write the CLI's own line of output. It is
deliberately not a general-purpose library.

Lean does ship `Lean.Data.Json`, and this port does not use it. Two
reasons, and both are contract rather than taste. Its objects are an
`RBNode` keyed by name, so field order is the SORTED order and not the
authored one - and a SigV4-signed request body is signed in the order it
was written. And it lives in the `Lean` package, the compiler's own
library, which a shipped secrets library has no business importing.

An inductive rather than a bare value: a vault answering `null`, `false`,
`0` and "no such key" means four different things, and a closed value
model keeps them apart at compile time rather than by convention. `parse`
answers `Option Json`, where `none` means "this text is not JSON" and
`some Json.null` means "this text is the JSON literal null" - a
distinction fetchjson's callers need, since only the first is a
malformed response.

A port of typescript/src/Json.ts, which is canonical.
-/

import Sekreto.Text

namespace Sekreto

/-- An insertion-ordered association list. A JSON object's field order is
signed, so the whole library carries key/value data this way rather than
in a hash map. -/
abbrev Pairs (α : Type) : Type := List (String × α)

namespace Pairs

/-- The value under `key`, or none. -/
def find? {α : Type} (entries : Pairs α) (key : String) : Option α :=
  match entries with
  | [] => none
  | (name, value) :: rest => if name == key then some value else find? rest key

/-- Set `key`, in place if it is already there and appended if it is not,
so the order a caller wrote is the order that comes back.

Named `put` and not `set`: `Pairs` is an abbreviation for `List`, and a
`List.set` that takes an index is already in scope for dot notation. -/
def put {α : Type} (entries : Pairs α) (key : String) (value : α) : Pairs α :=
  match entries with
  | [] => [(key, value)]
  | (name, held) :: rest =>
    if name == key then (name, value) :: rest else (name, held) :: put rest key value

/-- The keys, in order. -/
def keys {α : Type} (entries : Pairs α) : List String := entries.map Prod.fst

end Pairs

/-- A JSON value. Numbers are `Float` only: there is no integer case
anywhere in this library, which is what keeps a payload read from one
store and written to another byte-identical.

The object case spells `List (String × Json)` out rather than using the
`Pairs` abbreviation: Lean's nested-inductive check unfolds `List` but
not an `abbrev` over it. -/
inductive Json where
  | null
  | bool (value : Bool)
  | num (value : Float)
  | str (value : String)
  | arr (value : List Json)
  | obj (value : List (String × Json))
  deriving Inhabited

namespace Json

/-- Render a string as a JSON string literal, quotes included. Public,
because the CLI assembles its output line field by field. -/
def quote (text : String) : String :=
  let escape (ch : Char) : String :=
    if '"' == ch then "\\\""
    else if '\\' == ch then "\\\\"
    else if '\n' == ch then "\\n"
    else if '\r' == ch then "\\r"
    else if '\t' == ch then "\\t"
    else if ch.toNat < 0x20 then "\\u00" ++ hexbyte (UInt8.ofNat ch.toNat)
    else String.singleton ch
  "\"" ++ text.toList.foldl (fun out ch => out ++ escape ch) "" ++ "\""

/-- Render a value as compact JSON: no spaces, no newlines. -/
partial def stringify : Json → String
  | .null => "null"
  | .bool value => if value then "true" else "false"
  | .num value => numstr value
  | .str value => quote value
  | .arr entries => "[" ++ String.intercalate "," (entries.map stringify) ++ "]"
  | .obj entries =>
    "{" ++ String.intercalate ","
      (entries.map (fun kv => quote kv.1 ++ ":" ++ stringify kv.2)) ++ "}"

instance : ToString Json := ⟨stringify⟩

def asstr : Json → Option String
  | .str value => some value
  | _ => none

def asnum : Json → Option Float
  | .num value => some value
  | _ => none

def asbool : Json → Option Bool
  | .bool value => some value
  | _ => none

def asarr : Json → Option (List Json)
  | .arr value => some value
  | _ => none

def asobj : Json → Option (List (String × Json))
  | .obj value => some value
  | _ => none

/-- One step into an object; nothing for any other shape. -/
def get? (value : Json) (key : String) : Option Json :=
  match value with
  | .obj entries => Pairs.find? entries key
  | _ => none

/-- This value as the text a caller would print, or none when there is no
value at all. A JSON null is "no value": every provider here treats it as
a MISS rather than as the string "null". -/
def text : Json → Option String
  | .null => none
  | .str value => some value
  | .num value => some (numstr value)
  | .bool value => some (if value then "true" else "false")
  | other => some (stringify other)

/-- An object, in the order given: a payload's field order is signed. -/
def object (entries : List (String × Json)) : Json := .obj entries

end Json

-- The same reads on an optional value, so a provider can walk a response
-- body - which is `Option Json`, because a store may not have answered
-- with JSON at all - without unwrapping at every step.
namespace OptJson

/-- Walk nested objects; nothing the moment a step is not there. -/
def dig (value : Option Json) (keys : List String) : Option Json :=
  keys.foldl (fun held key => held.bind (fun found => found.get? key)) value

def text (value : Option Json) : Option String := value.bind Json.text
def asstr (value : Option Json) : Option String := value.bind Json.asstr
def asnum (value : Option Json) : Option Float := value.bind Json.asnum
def asarr (value : Option Json) : Option (List Json) := value.bind Json.asarr
def asobj (value : Option Json) : Option (List (String × Json)) := value.bind Json.asobj

end OptJson

/-- Reader state: the remaining characters, and how deep the value model
is nested. -/
private structure Reader where
  rest : List Char
  depth : Nat

/-- The nesting a response body may reach before it is refused. A body
arrives before any trust check has been made of it, and `[[[[...` on a
recursive-descent parser is a stack overflow - which is the process, not
an error. -/
private def MAXDEPTH : Nat := 128

private def skipws (reader : Reader) : Reader :=
  { reader with rest := reader.rest.dropWhile Char.isWhitespace }

private def isnumchar (ch : Char) : Bool :=
  ('0' ≤ ch && ch ≤ '9') || '-' == ch || '+' == ch || '.' == ch || 'e' == ch || 'E' == ch

private def isdigit (ch : Char) : Bool := '0' ≤ ch && ch ≤ '9'

/-- A JSON number, read by hand.

Lean 4.16 has no `String.toFloat?`, so the digits are read into a `Nat`
mantissa and a decimal exponent and handed to `Float.ofScientific`, which
is the platform's own decimal-to-binary conversion. A span that is not a
number at all, and a value that comes back non-finite - `1e999` does -
are both refused: JSON has no infinity, and an infinite expiry would
later be arithmetic on something that is not a number. -/
private def readnum (span : List Char) : Option Float :=
  let (negative, body) := match span with
    | '-' :: rest => (true, rest)
    | rest => (false, rest)

  let whole := body.takeWhile isdigit
  if whole.isEmpty then none else

  let afterwhole := body.drop whole.length

  let (frac, afterfrac) := match afterwhole with
    | '.' :: rest =>
      let digits := rest.takeWhile isdigit
      (digits, rest.drop digits.length)
    | rest => ([], rest)

  let expres : Option Int := match afterfrac with
    | [] => some 0
    | mark :: rest =>
      if 'e' != mark && 'E' != mark then none
      else
        let (esign, edigits) := match rest with
          | '-' :: more => (true, more)
          | '+' :: more => (false, more)
          | more => (false, more)
        let digits := edigits.takeWhile isdigit
        if digits.isEmpty || digits.length != edigits.length then none
        else match (String.mk digits).toNat? with
          | none => none
          | some size => some (if esign then -(Int.ofNat size) else Int.ofNat size)

  match expres with
  | none => none
  | some exponent =>
    match (String.mk (whole ++ frac)).toNat? with
    | none => none
    | some mantissa =>
      let scale := exponent - Int.ofNat frac.length
      let value :=
        if scale < 0 then Float.ofScientific mantissa true (Int.toNat (-scale))
        else Float.ofScientific mantissa false (Int.toNat scale)
      if value.isNaN || value.isInf then none
      else some (if negative then -value else value)

/-- Read four hex digits as one UTF-16 code unit. No surrogate-pair
recombination, in this port or any other. -/
private def readhex4 (chars : List Char) : Option (Char × List Char) :=
  match chars with
  | a :: b :: c :: d :: rest => do
    let ha ← hexdigit a
    let hb ← hexdigit b
    let hc ← hexdigit c
    let hd ← hexdigit d
    some (Char.ofNat (((ha * 16 + hb) * 16 + hc) * 16 + hd), rest)
  | _ => none

private partial def readstr (chars : List Char) (out : String) : Option (String × List Char) :=
  match chars with
  | [] => none
  | '"' :: rest => some (out, rest)
  | '\\' :: escape :: rest =>
    if '"' == escape then readstr rest (out.push '"')
    else if '\\' == escape then readstr rest (out.push '\\')
    else if '/' == escape then readstr rest (out.push '/')
    else if 'b' == escape then readstr rest (out.push (Char.ofNat 8))
    else if 'f' == escape then readstr rest (out.push (Char.ofNat 12))
    else if 'n' == escape then readstr rest (out.push '\n')
    else if 'r' == escape then readstr rest (out.push '\r')
    else if 't' == escape then readstr rest (out.push '\t')
    else if 'u' == escape then
      match readhex4 rest with
      | some (ch, more) => readstr more (out.push ch)
      | none => none
    else none
  | ch :: rest => readstr rest (out.push ch)

private def word (chars : List Char) (want : String) : Option (List Char) :=
  let wanted := want.toList
  if wanted.isPrefixOf chars then some (chars.drop wanted.length) else none

mutual

private partial def readvalue (reader : Reader) : Option (Json × Reader) :=
  if MAXDEPTH < reader.depth then none else
  let reader := skipws reader
  match reader.rest with
  | [] => none
  | '{' :: rest => readobj { rest := rest, depth := reader.depth + 1 } []
  | '[' :: rest => readarr { rest := rest, depth := reader.depth + 1 } []
  | '"' :: rest =>
    match readstr rest "" with
    | none => none
    | some (value, more) => some (Json.str value, { reader with rest := more })
  | 't' :: _ =>
    (word reader.rest "true").map (fun more => (Json.bool true, { reader with rest := more }))
  | 'f' :: _ =>
    (word reader.rest "false").map (fun more => (Json.bool false, { reader with rest := more }))
  | 'n' :: _ =>
    (word reader.rest "null").map (fun more => (Json.null, { reader with rest := more }))
  | _ =>
    let span := reader.rest.takeWhile isnumchar
    match readnum span with
    | none => none
    | some value => some (Json.num value, { reader with rest := reader.rest.drop span.length })

private partial def readobj (reader : Reader) (out : List (String × Json)) : Option (Json × Reader) :=
  let reader := skipws reader
  match reader.rest with
  | '}' :: rest => some (Json.obj out, { reader with rest := rest, depth := reader.depth - 1 })
  | '"' :: rest =>
    match readstr rest "" with
    | none => none
    | some (key, more) =>
      let after := skipws { reader with rest := more }
      match after.rest with
      | ':' :: tail =>
        match readvalue { after with rest := tail } with
        | none => none
        | some (value, next) =>
          let next := skipws next
          match next.rest with
          | ',' :: tail => readobj { next with rest := tail } (out ++ [(key, value)])
          | '}' :: tail =>
            some (Json.obj (out ++ [(key, value)]),
              { next with rest := tail, depth := next.depth - 1 })
          | _ => none
      | _ => none
  | _ => none

private partial def readarr (reader : Reader) (out : List Json) : Option (Json × Reader) :=
  let reader := skipws reader
  match reader.rest with
  | ']' :: rest => some (Json.arr out, { reader with rest := rest, depth := reader.depth - 1 })
  | _ =>
    match readvalue reader with
    | none => none
    | some (value, next) =>
      let next := skipws next
      match next.rest with
      | ',' :: tail => readarr { next with rest := tail } (out ++ [value])
      | ']' :: tail =>
        some (Json.arr (out ++ [value]), { next with rest := tail, depth := next.depth - 1 })
      | _ => none

end

namespace Json

/-- Parse JSON text. Nothing for anything unreadable - which the caller
must tell apart from a literal `null` body, since only the first means
the store could not answer coherently. -/
def parse (text : String) : Option Json :=
  if text.isEmpty then none
  else
    match readvalue { rest := text.toList, depth := 0 } with
    | none => none
    -- Trailing content after the top-level value is not JSON.
    | some (value, reader) => if (skipws reader).rest.isEmpty then some value else none

end Json

end Sekreto
