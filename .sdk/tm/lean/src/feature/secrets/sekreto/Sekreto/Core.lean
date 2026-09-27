-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lean/src/Sekreto/Core.lean)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/-
The pure core of sekreto: names, keys, `.env` text and redaction.

Everything here is a total function over strings, with no platform
underneath it - nothing reads a file, opens a socket or samples a clock.
The chain that uses them is `Sekreto.Chain`, the providers are
`Sekreto.Builtin` and the plugin modules, and this module is what all
three agree about.

Two shapes of failure, and they are never interchangeable. A store that
does not hold the secret is a MISS (`none`) and the chain carries on. A
store that could not ANSWER throws. Getting that backwards makes a chain
fall silently through to a weaker store, which is the worst failure this
library has.

Lean has no exception type of its own to subclass, and `SekretoError`
carries a message and nothing else in every port, so a refusal here is
`IO.userError message` - whose `toString` IS the message, byte for byte.
The pure functions that can refuse answer `Except String String`
instead, because Lean's are pure and a caller that has no `IO` to run in
still has to be able to ask.

The pure half of typescript/src/Sekreto.ts, which is canonical.
-/

import Sekreto.Text
import Sekreto.Json

namespace Sekreto

/-- Anything sekreto refuses to do: a bad name, a missing secret, a
provider that could not be reached. The message is the whole contract -
no code, no fields, no cause. -/
def sekretoError (message : String) : IO.Error := IO.userError message

/-- Refuse, in `IO`. -/
def fail {α : Type} (message : String) : IO α := throw (sekretoError message)

/-- Carry a pure refusal into `IO` unchanged. -/
def ofResult {α : Type} : Except String α → IO α
  | .ok value => pure value
  | .error message => fail message

/-- Is this a well-formed secret name: dot-separated `[a-z0-9_]+`?

Never raises, whatever it is handed. The check is a character scan and
not a regex on purpose: in Python, PCRE, Perl and .NET `$` also matches
before a final newline, so `api.token\n` passed in four ports. The corpus
pins that case, and the two like it, as false. -/
def validname (name : String) : Bool :=
  !name.isEmpty && (segments name).all namepart

/-- The name, or a refusal. Every entry point checks its name here. -/
def checkname (name : String) : Except String String :=
  if validname name then .ok name else .error ("sekreto: invalid name: " ++ name)

/-- The environment-variable key for a name: `api.token` -> `API_TOKEN`.
The prefix is NOT uppercased - it is written as it is meant. -/
def envkey (name : String) (pre : String := "") : Except String String := do
  let checked ← checkname name
  return pre ++ asciiupper (String.intercalate "_" (segments checked))

/-- Where a name lives in a KV vault. -/
structure VaultRef where
  path : String
  field : String
  deriving Inhabited

/-- Where a name lives in a KV vault: `api.token` -> `api` / `token`.

A single-segment name has no path of its own, so it becomes a secret of
that name with the conventional field `value`. -/
def vaultref (name : String) : Except String VaultRef := do
  let parts := segments (← checkname name)
  match parts with
  | [only] => return { path := only, field := "value" }
  | _ =>
    let field := parts.getLast!
    return { path := String.intercalate "/" (parts.dropLast), field := field }

/-- A name flattened to one segment: `api.token` -> `api_token` (GCP
Secret Manager, `_`) or `api-token` (Azure Key Vault, `-`).

Those stores have no path hierarchy and reject dots in ids, so the dots
become the store's conventional separator. With `-` as the separator,
underscores flatten too: Azure Key Vault's alphabet is letters, digits
and hyphens only, and a valid sekreto name like `with_underscore` must
still be representable there. -/
def flatname (name : String) (sep : String) : Except String String := do
  let flat := String.intercalate sep (segments (← checkname name))
  return if "-" == sep then replaceAll flat "_" "-" else flat

/-- The AWS SSM Parameter Store name for a name: dots become the path
hierarchy, rooted at `/` (or at a prefix): `db.pass.main` ->
`/db/pass/main`, or `/app/db/pass/main` under prefix `/app`. -/
def awsparam (name : String) (pre : String := "") : Except String String := do
  let checked ← checkname name
  let rooted := if !pre.isEmpty && !pre.startsWith "/" then "/" ++ pre else pre
  let base := dropsuffix rooted "/"
  return base ++ "/" ++ String.intercalate "/" (segments checked)

/-- Unescape a double-quoted `.env` value.

A scan, not a chain of replacements: `\n \r \t \\ \"` are the whole
alphabet, ANY OTHER escape is preserved as backslash plus character, and
a trailing backslash is literal. -/
private partial def unescape (chars : List Char) (out : String) : String :=
  match chars with
  | [] => out
  | '\\' :: next :: rest =>
    if 'n' == next then unescape rest (out.push '\n')
    else if 'r' == next then unescape rest (out.push '\r')
    else if 't' == next then unescape rest (out.push '\t')
    else if '\\' == next then unescape rest (out.push '\\')
    else if '"' == next then unescape rest (out.push '"')
    else unescape rest ((out.push '\\').push next)
  | ch :: rest => unescape rest (out.push ch)

private def unquote (value : String) : String :=
  if 2 ≤ value.length && value.startsWith "\"" && value.endsWith "\"" then
    unescape (value.drop 1 |>.dropEnd 1 |>.toString.toList) ""
  else if 2 ≤ value.length && value.startsWith "'" && value.endsWith "'" then
    (value.drop 1 |>.dropEnd 1).toString
  else value

/-- Parse `.env` text into ordered raw keys and values.

There is no `.env` standard, so this function is the specification.
Deliberately small: `KEY=value`, an optional `export`, `#` comments on
their own line, and single- or double-quoted values (double quotes also
unescape). A line with no `=`, or with an empty key, is skipped SILENTLY
- it does not abort the lines after it. Never raises. -/
def parsedotenv (text : String) : Pairs String :=
  (text.splitOn "\n").foldl (fun out rawline =>
    let line := (dropsuffix rawline "\r").trim
    if line.isEmpty || line.startsWith "#" then out
    else
      let entry := if line.startsWith "export " then (line.drop 7).trim.toString else line
      match indexOfChar entry '=' with
      | none => out
      -- `eq <= 0` skips both "no `=`" and "empty key".
      | some 0 => out
      | some eq =>
        let key := (entry.take eq).trim.toString
        let value := (entry.drop (eq + 1)).trim.toString
        Pairs.put out key (unquote value)) []

/-- Replace known secret values in text with `[redacted]`.

Only values of four characters or more are replaced: shorter ones are
too likely to appear in ordinary text, and redacting them would make
logs unreadable without making them safer.

LONGEST FIRST, always, and over a COPY of the caller's list - `values` is
`seen` when this is called through `Sekreto.redactText`, and reordering
it would reorder the live redaction history. The replacement is a literal
substring pass and not a pattern, so a secret full of metacharacters is
not interpreted. -/
def redact (text : String) (values : List String) : String :=
  let usable := values.filter (fun value => 4 ≤ value.length)
  let ordered := usable.mergeSort (fun left right => right.length ≤ left.length)
  ordered.foldl (fun out value => replaceAll out value "[redacted]") text

end Sekreto
