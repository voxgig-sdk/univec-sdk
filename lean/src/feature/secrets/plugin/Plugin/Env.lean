-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lean/src/Plugin/Env.lean)
-- Source: https://github.com/voxgig/plugin @ 48392f5e2b6d1434ee9b1a4a9a11f4480aaeb46a  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
import Plugin.Ref

/-!
# Environment overrides (§9.5) — level 7 of the ladder

One prefix, so nothing drifts: `VOXGIG_PLUGIN_*`.

    VOXGIG_PLUGIN_PROFILE            the profile name
    VOXGIG_PLUGIN_<REF>_<PATH>       one option
    VOXGIG_PLUGIN_ACTIVE/INACTIVE    comma-separated refs, INACTIVE wins

THE ENCODING IS LOSSY, AND THIS SAYS SO RATHER THAN PRETENDING
OTHERWISE. Ref and path are upper-snake with `$` -> `__` and `.` -> `_`.
But `_` is legal in a name and in a tag, and the mapping folds case, so
`retry$fast` and `retry__fast` both encode to `RETRY__FAST`.

Rather than restrict a grammar the rest of the stack already uses, the
host DETECTS THE COLLISION: it encodes every ref it holds, and a key two
refs claim is `plugin_env_ambiguous`, naming both.
-/

namespace Plugin

def envPrefix : String := "VOXGIG_PLUGIN_"

def encodeRef (r : String) : String :=
  String.join (r.toList.map (fun c =>
    if c == '$' then "__"
    else if c == '.' then "_"
    else String.mk [c.toUpper]))

private def checkReserved (r : String) (reserved : Value) : PluginM Unit := do
  if reserved.isList && reserved.len > 0 then
    if (reserved.items).any (fun x => x.isStr && x.asStr == refName r) then
      raise "plugin_ref_reserved" ("ref is reserved by the host: " ++ r)
        (details1 "ref" (.str r))

/-- Values parse as JSON, FALLING BACK TO STRING — so `8080` is a
number, `true` is a boolean, `{"a":1}` is a map, and `hello` is the
string it looks like rather than a parse error. -/
private def parseValue (s : String) : Value :=
  match Value.parse s with
  | .ok v => v
  | .error _ => .str s

private def lower (s : String) : String := String.mk (s.toList.map Char.toLower)

private def trim (s : String) : String :=
  String.mk ((s.toList.dropWhile (fun c => c == ' ' || c == '\t')).reverse.dropWhile
    (fun c => c == ' ' || c == '\t')).reverse

/-- LONGEST encoded ref first, so `retry$fast` wins over `retry` on
`RETRY__FAST_MIN`. Shortest-first would read the tag as a path. -/
private def byLenDesc (a b : String) : Bool :=
  if a.length != b.length then a.length > b.length else Value.strLe a b

private partial def setPath (node : Value) (segs : List String) (v : Value) : Value :=
  match segs with
  | [] => node
  | [leaf] => node.set leaf v
  | seg :: more =>
    let next := let x := node.get seg; if x.isMap then x else Value.vmap
    node.set seg (setPath next more v)

def applyEnv (input : Value) : PluginM Value := do
  let env := let e := input.get "env"; if e.isMap then e else Value.vmap
  let refsIn := input.get "refs"
  let reserved := input.get "reserved"

  -- Encode every ref the host holds, and refuse a key that two of them
  -- claim. Done UP FRONT so the collision is reported even when no
  -- environment variable exercises it — a latent ambiguity is still an
  -- ambiguity, and finding it at deploy time is the failure this exists
  -- to prevent.
  let mut byEncoded := Value.vmap
  if refsIn.isList then
    for rv in refsIn.items do
      let r ← canonRef rv
      let e := encodeRef r
      let l := let x := byEncoded.get e; if x.isList then x else Value.vlist
      byEncoded := byEncoded.set e (l.push (.str r))

  let encs := byEncoded.sortedKeys
  for e in encs do
    let claims := byEncoded.get e
    if claims.len > 1 then
      let a := (claims.idx 0).asStr
      let b := (claims.idx 1).asStr
      let lo := if Value.strLe a b then a else b
      let hi := if Value.strLe a b then b else a
      let d := (Value.vmap.set "encoded" (.str e)).set "refs" (.list [.str lo, .str hi])
      raise "plugin_env_ambiguous"
        ("refs collide in the environment encoding as " ++ e ++ ": " ++ lo ++ ", " ++ hi) d

  let order := Value.sortWith byLenDesc encs

  let mut out :=
    ((Value.vmap.set "options" Value.vmap).set "active" Value.vlist).set "inactive" Value.vlist

  for key in env.sortedKeys do
    if !key.startsWith envPrefix then continue
    let rest := (key.drop envPrefix.length).toString
    let raw := env.get key
    let val := if raw.isStr then raw.asStr else ""

    if rest == "PROFILE" then
      out := out.set "profile" (.str val)
      continue

    if rest == "ACTIVE" || rest == "INACTIVE" then
      let slot := if rest == "ACTIVE" then "active" else "inactive"
      for piece in val.splitOn "," do
        let p := trim piece
        if p == "" then continue
        let c ← canonRefS p
        -- The reservation covers EVERY input layer (§9.1).
        -- VOXGIG_PLUGIN_INACTIVE=station is easier to set than editing a
        -- config file, and INACTIVE has the final word — so guarding
        -- documents alone would leave the one lever this mechanism
        -- exists to deny wide open.
        checkReserved c reserved
        out := out.set slot ((out.get slot).push (.str c))
      continue

    let enc? := order.find? (fun cand =>
      rest == cand ||
        (rest.length > cand.length && rest.startsWith cand
          && (rest.drop cand.length).toString.startsWith "_"))
    match enc? with
    -- not for any ref this host holds
    | none => continue
    | some enc =>
      let r := ((byEncoded.get enc).idx 0).asStr
      checkReserved r reserved
      -- A ref with no path sets nothing.
      if rest == enc then continue
      let pathText := (rest.drop (enc.length + 1)).toString
      let segs := (pathText.splitOn "_").map lower
      let options := out.get "options"
      let node := let x := options.get r; if x.isMap then x else Value.vmap
      out := out.set "options" (options.set r (setPath node segs (parseValue val)))

  return out

end Plugin
