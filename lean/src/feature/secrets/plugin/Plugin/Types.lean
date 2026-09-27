-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lean/src/Plugin/Types.lean)
-- Source: https://github.com/voxgig/plugin @ 48392f5e2b6d1434ee9b1a4a9a11f4480aaeb46a  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
import Plugin.Value

/-!
# Errors, and the raise mechanism (§12)

`ExceptT PluginError IO`, AND THE CHOICE IS BETWEEN THAT AND `IO.Error`.
Lean's own `IO.Error` carries a string and nothing else, so an error's
CODE — the thing every port compares by (§12) — would have to be dug
back out of the message. A typed error monad keeps the code, the text
and the details as fields, and `IO` actions lift into it, so the host's
`IO.Ref` state costs nothing extra.

Ports compare by CODE and never by message: wording is a port's own
business. The FORMAT is pinned, because a parseable message is what
makes a log searchable across twenty languages.
-/

namespace Plugin

structure PluginError where
  code : String
  text : String
  details : Value
  message : String
  deriving Inhabited

abbrev PluginM := ExceptT PluginError IO

/-- §12's detail fields, IN THIS FIXED ORDER. The order is part of the
contract: an earlier draft named six fields while other sections
promised diagnostics with nowhere to go, which would have left each port
inventing its own order and breaking message parity. -/
def detailOrder : List String :=
  ["host", "ref", "name", "tag", "point", "key", "capability",
   "range", "version", "match", "candidates", "cycle", "holders",
   "refs", "path", "cause"]

/-- Values render as COMPACT JSON, so a value containing a space or a
bracket cannot break the parse and a list renders as an array. The
bracket is absent entirely when no field applies. -/
def formatError (code text : String) (details : Value) : String :=
  let parts := detailOrder.filterMap (fun k =>
    if details.has k then some (k ++ "=" ++ Value.json (details.get k)) else none)
  let headline := "plugin/" ++ code ++ ": " ++ text
  if parts.isEmpty then headline
  else headline ++ " [" ++ String.intercalate " " parts ++ "]"

def mkError (code text : String) (details : Value := Value.vmap) : PluginError :=
  { code, text, details, message := formatError code text details }

/-- Raise. -/
def raise (code text : String) (details : Value := Value.vmap) : PluginM α :=
  throw (mkError code text details)

def details1 (k : String) (v : Value) : Value := Value.vmap.set k v

def details2 (k1 : String) (v1 : Value) (k2 : String) (v2 : Value) : Value :=
  (Value.vmap.set k1 v1).set k2 v2

/-- Deep merge, struct's semantics: maps merge, everything else
replaces. §16 permits voxgig/struct for this and Lean has no port of
it. -/
partial def mergeValue (a b : Value) : Value :=
  if !(a.isMap && b.isMap) then b
  else
    (b.keys).foldl
      (fun acc k =>
        let bv := b.get k
        let av := acc.get k
        acc.set k (if av.isMap && bv.isMap then mergeValue av bv else bv))
      ((a.keys).foldl (fun acc k => acc.set k (a.get k)) Value.vmap)

/-- §11.1's partial match: every leaf in `want` must be present and
equal in `have`; keys not mentioned are not checked. -/
partial def matchValue (want have_ : Value) : Bool :=
  if want.isNull then true
  else if want.isMap then
    have_.isMap && (want.keys).all (fun k => have_.has k && matchValue (want.get k) (have_.get k))
  else Value.same want have_

end Plugin
