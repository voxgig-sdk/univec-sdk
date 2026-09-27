-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lean/src/Plugin/Resolve.lean)
-- Source: https://github.com/voxgig/plugin @ 48392f5e2b6d1434ee9b1a4a9a11f4480aaeb46a  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
import Plugin.Value

/-!
# Dynamic resolution (§10.2) — name to candidate module ids

PURE. It returns the ids a host WOULD try, in order; it does not load
anything. That separation is what lets the corpus pin resolution in
every language including those with no dynamic loading at all — lean is
tier S in §10.3's table, static registration only — and it is why §15.4
puts real module loading in per-port integration tests rather than here.

Total, and outside `PluginM`, because nothing here can fail.
-/

namespace Plugin

private def pushUniq (acc : List String) (x : String) : List String :=
  if acc.contains x then acc else acc ++ [x]

def defaultPrefix : List String :=
  ["@voxgig/plugin-", "voxgig-plugin-", "plugin-", ""]

def resolveCandidates (name sources : Value) : Value :=
  let n := if name.isStr then name.asStr else ""
  -- A SCOPED NAME RESOLVES VERBATIM ONLY (§10.2). `@acme/thing` is
  -- already a package id; prefixing it produces
  -- `@voxgig/plugin-@acme/thing`, which is not a thing that can exist.
  if n.startsWith "@" then .list [.str n]
  else if !(sources.isList && sources.len > 0) then
    .list ((defaultPrefix.foldl (fun acc p => pushUniq acc (p ++ n)) []).map Value.str)
  else
    let step := fun (acc : List String) (src : Value) =>
      let kind := (src.get "kind").asStr
      if kind == "module" then
        let pfx := src.get "prefix"
        if pfx.isList && pfx.len > 0 then
          (pfx.items).foldl (fun a p => pushUniq a (p.asStr ++ n)) acc
        else pushUniq acc n
      else if kind == "path" then
        -- Trailing slashes are trimmed, so `lib/` and `lib` give one id
        -- rather than two spellings of it.
        let dir := String.mk ((src.get "dir").asStr.toList.reverse.dropWhile (· == '/')).reverse
        pushUniq acc (dir ++ "/" ++ n)
      else acc
    .list (((sources.items).foldl step []).map Value.str)

/-- A MODULE PATH IS NOT A NAME (§10.2). The ref grammar starts a name
with a letter or `@`, so `./local/thing` is not a ref and never reaches
candidate generation — seneca allows a path where a plugin name goes,
and this design deliberately does not, because a ref is an ADDRESS
WITHIN A HOST and a path is a LOCATION ON A DISK.

Loading from an explicit location bypasses candidate generation
entirely: `from` is passed to the resolver verbatim. -/
def resolveFrom (from_ : Value) : Value :=
  .list [if from_.isNull then .null else from_]

end Plugin
