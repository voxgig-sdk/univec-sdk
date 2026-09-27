-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lean/src/Plugin/Ref.lean)
-- Source: https://github.com/voxgig/plugin @ 48392f5e2b6d1434ee9b1a4a9a11f4480aaeb46a  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
import Plugin.Types

/-!
# Identity: name+tag, written `name$tag` (§4)

The four pure functions, and the whole of what `ref` pins. They are the
first thing a new port implements and the first corpus section it
passes.

`checkname` and `checktag` are total and answer `Bool`; `parseRef`,
`formatRef` and `canonRef` are in `PluginM` because they raise.
-/

namespace Plugin

def maxRef : Nat := 1024

def isNameHead (c : Char) : Bool :=
  ('a' ≤ c && c ≤ 'z') || ('A' ≤ c && c ≤ 'Z') || c == '@'

def isNameBody (c : Char) : Bool :=
  ('a' ≤ c && c ≤ 'z') || ('A' ≤ c && c ≤ 'Z') || ('0' ≤ c && c ≤ '9')
    || c == '.' || c == '~' || c == '_' || c == '-' || c == '/'

def isTagChar (c : Char) : Bool :=
  ('a' ≤ c && c ≤ 'z') || ('A' ≤ c && c ≤ 'Z') || ('0' ≤ c && c ≤ '9')
    || c == '.' || c == '~' || c == '_' || c == '-'

def namely (name : String) : Bool :=
  match name.toList with
  | [] => false
  | c :: rest => name.length ≤ maxRef && isNameHead c && rest.all isNameBody

/-- The empty tag is an ordinary tag (§4 rule 2). The single-instance
case writes no tag and never learns tags exist. -/
def tagly (tag : String) : Bool :=
  if tag == "" then true
  else tag.length ≤ maxRef && tag.toList.all isTagChar

/-- A non-string is not a name. Every port has to answer this the same
way, and `ref/name` pins it for numbers, nulls and maps alike. -/
def checkname (name : Value) : Bool := name.isStr && namely name.asStr

/-- The asymmetry with a name is deliberate: a tag MAY start with a
digit because auto-tagging assigns integer tags (`stripe$1`), and a tag
admits neither `@` nor `/` because a name is a package specifier and a
tag is not. -/
def checktag (tag : Value) : Bool := tag.isStr && tagly tag.asStr

/-- Split on the FIRST `$`. Nothing in the grammar decides this — `$` is
in neither character class — so the corpus is the arbiter (§4 rule 5),
and it picks the split that blames the part actually at fault: `a$b$c`
is a good name with a bad tag, not the reverse. -/
def splitRef (s : String) : String × String :=
  let cs := s.toList
  let name := cs.takeWhile (· != '$')
  let rest := cs.dropWhile (· != '$')
  match rest with
  | [] => (String.mk name, "")
  | _ :: tag => (String.mk name, String.mk tag)

def parseRef (str : Value) : PluginM Value := do
  if !str.isStr then raise "plugin_bad_name" "ref must be a string"
  let (name, tag) := splitRef str.asStr
  if !namely name then
    raise "plugin_bad_name" ("invalid plugin name: " ++ name) (details1 "name" (.str name))
  if !tagly tag then
    raise "plugin_bad_tag" ("invalid plugin tag: " ++ tag)
      (details2 "name" (.str name) "tag" (.str tag))
  return (Value.vmap.set "name" (.str name)).set "tag" (.str tag)

/-- An empty tag NEVER writes the separator, which is the half of
canonicalization `formatRef` owns: parse tolerates `stripe$`, format
never produces it, so a round trip is idempotent. -/
def formatRef (name tag : Value) : PluginM String := do
  let tagok := tag.isNull || tag.isStr
  let t := if tag.isStr then tag.asStr else ""
  if !checkname name then
    raise "plugin_bad_name"
      ("invalid plugin name: " ++ (if name.isStr then name.asStr else ""))
      (details1 "name" (if name.isNull then .null else name))
  if !tagok || !tagly t then
    raise "plugin_bad_tag" ("invalid plugin tag: " ++ t)
      (details2 "name" name "tag" (if tag.isNull then .str "" else tag))
  return (if t == "" then name.asStr else name.asStr ++ "$" ++ t)

/-- The canonical spelling. §4 rule 5: canonicalize before comparison. -/
def canonRef (str : Value) : PluginM String := do
  let r ← parseRef str
  formatRef (r.get "name") (r.get "tag")

def canonRefS (s : String) : PluginM String := canonRef (.str s)

/-- The canonical ref this string denotes, or `none` if it denotes none
— the TOLERANT half of `canonRef`, and the one a requirement name needs
(§11.1). Capability names are free-form, so `2fa` is a good one and no
ref could be called that; `canonRef` RAISES on those, and asking it "is
this a ref?" made a legal document kill the host.

An `Option`, so a caller cannot mistake "not a ref" for "the empty ref"
— and total, because it answers rather than raises. -/
def tryRef (s : String) : Option String :=
  let (name, tag) := splitRef s
  if !namely name || !tagly tag then none
  else some (if tag == "" then name else name ++ "$" ++ tag)

/-- `canonRef` for internal callers that want the input back unchanged
when it is not well formed. NEVER use where a bad ref must be reported —
the corpus pins `plugin_bad_name` at every public entry. -/
def canon (s : String) : String := (tryRef s).getD s

/-- The name half, for internal callers that only compare. -/
def refName (s : String) : String :=
  let (name, _) := splitRef s
  if namely name then name else s

end Plugin
