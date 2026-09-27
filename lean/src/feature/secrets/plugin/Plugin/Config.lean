-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lean/src/Plugin/Config.lean)
-- Source: https://github.com/voxgig/plugin @ 48392f5e2b6d1434ee9b1a4a9a11f4480aaeb46a  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
import Plugin.Ref

/-!
# The declarative document (§9): normalization, and the ten-level ladder

TWO FUNCTIONS, AND THE SPLIT BETWEEN THEM IS FORCED.

`normalizeConfig` normalizes STRUCTURE and ENTRY KEYS. It does not merge
options, and cannot: §9.4 makes merge behaviour a property of the
definition's option SHAPE, which normalization has never seen. A
normalizer that flattened the option layers would make `$MERGE: append`
unimplementable at load time, because the layers it must concatenate
would already be collapsed.

`resolveOptions` applies the ladder, and it is the only place that knows
the shape.
-/

namespace Plugin

/-- §9.1: reservation is all-or-nothing per NAME, so the tagged forms go
too. A configuration surface that can disable the thing reading it is
not a surface, it is a trap. -/
private def checkReserved (r : String) (reserved : Value) : PluginM Unit := do
  if reserved.isList && reserved.len > 0 then
    if (reserved.items).any (fun x => x.isStr && x.asStr == refName r) then
      raise "plugin_ref_reserved" ("ref is reserved by the host: " ++ r)
        (details1 "ref" (.str r))

/-- Both document forms reduce to `{ref -> entry}` plus the order the
form implies: array POSITION for the array form, sorted refs for the map
form. -/
private def entriesOf (src : Value) : PluginM (Value × List String) := do
  if src.isNull then return (Value.vmap, [])
  if src.isList then
    let mut m := Value.vmap
    let mut order : List String := []
    for item in src.items do
      let r ← canonRef (item.get "ref")
      m := m.set r item
      order := order ++ [r]
    return (m, order)
  -- Map-form refs arrive as KEYS, through a different path than an
  -- array element's `ref` field — and must canonicalize the same way.
  let mut m := Value.vmap
  for k in src.keys do
    m := m.set (← canonRefS k) (src.get k)
  -- Byte-wise, NOT locale-aware and NOT case-folded. All-lowercase refs
  -- sort identically under all three, so only mixed input discriminates:
  -- '@' is 0x40, uppercase 0x41-0x5A, lowercase 0x61-0x7A.
  return (m, m.sortedKeys)

/-- PRESENT WINS, EVEN WHEN THE VALUE IS NULL. The canonical is
`src && undefined !== src[key]`, and in JavaScript a key holding `null`
passes that test — so a profile's `order: null` clears a base ordering
block and `active: null` over a base `active: true` is falsy, and
barred. Testing for non-null instead treated an authored null as an
absent key, which is §9.1's distinction inverted. -/
private def pick (src : Value) (key : String) (dflt : Value) : Value :=
  if src.isMap && src.has key then src.get key else dflt

def normalizeConfig (input : Value) : PluginM Value := do
  let doc := let d := input.get "doc"; if d.isMap then d else Value.vmap
  let keySpec := input.get "keys"
  let keyOr := fun (k d : String) =>
    let x := keySpec.get k
    if x.isStr then x.asStr else d
  let ikey := keyOr "instance" "instance"
  let dkey := keyOr "default" "default"
  let reserved := input.get "reserved"
  let profile := input.get "profile"

  -- The rename is applied at TWO PLACES AND NO OTHERS: the document
  -- root, and every profile.<name> overlay root (§9.1). A rename applied
  -- only at the root would leave `profile.prod.sdk` untranslated and
  -- silently drop every environment override the host depends on.
  -- Recursing further would be worse: option data is the definition's.
  let baseInst := doc.get ikey
  let baseDef := let d := doc.get dkey; if d.isMap then d else Value.vmap
  let overlay := if profile.isStr then (doc.get "profile").get profile.asStr else .null
  let overInst := if overlay.isMap then overlay.get ikey else .null
  let overDef :=
    let d := if overlay.isMap then overlay.get dkey else .null
    if d.isMap then d else Value.vmap

  let (baseMap, baseOrder) ← entriesOf baseInst
  let (overMap, overOrder) ← entriesOf overInst

  for m in [baseMap, overMap, baseDef, overDef] do
    for k in m.keys do checkReserved k reserved

  -- A PARTIAL ARRAY IS NOT A FILTER (§9.1). sdkgen learned this the hard
  -- way: deriving order from a partial array silently dropped
  -- config-activated features. Refs in the base but absent from the
  -- overlay still load, in sorted position AFTER the listed ones. A
  -- profile may also INTRODUCE a ref the base never declared.
  --
  -- The remainder keeps the BASE's own order — array position for the
  -- array form, sorted refs for the map form. Re-sorting here would
  -- discard an array document's positional order entirely, which is the
  -- one thing the array form exists to express.
  let order := (overOrder ++ baseOrder).foldl
    (fun acc r => if acc.contains r then acc else acc ++ [r]) []

  let mut instMap := Value.vmap
  for (r, i) in Value.indexed order do
    let b := baseMap.get r
    let o := overMap.get r
    -- MERGE THE ENTRIES AS AUTHORED, THEN APPLY DEFAULTS TO THE RESULT
    -- (§9.3). A safety rule, not a tidiness one: if the overlay had its
    -- defaults filled in before merging it would carry a synthesized
    -- active:true and overwrite a base's false — silently re-enabling a
    -- deliberately disabled integration in production.
    let active := pick o "active" (pick b "active" (.bool true))
    let start := pick o "start" (pick b "start" (.str "eager"))
    let ord := pick o "order" (pick b "order" .null)
    -- Option layers, levels 3-6, IN LADDER ORDER. Never merged here.
    let nm := refName r
    let layers := ([baseDef.get nm, b, overDef.get nm, o]).foldl
      (fun acc src => if src.isMap && src.has "options" then acc ++ [src.get "options"] else acc) []
    let ent :=
      (((Value.vmap.set "pos" (.num (Float.ofNat i))).set "active" active).set "start" start).set
        "optionlayers" (.list layers)
    instMap := instMap.set r (if ord.isNull then ent else ent.set "order" ord)

  -- `default` DECLARES NOTHING (§9.3). It is a base for every instance
  -- of that definition; it does not create one, and an entry for a name
  -- with no instances is inert rather than an error — which is what
  -- makes a shared library of defaults shippable.
  let defOut :=
    (overDef.keys).foldl (fun m k => m.set k (overDef.get k))
      ((baseDef.keys).foldl (fun m k => m.set k (baseDef.get k)) Value.vmap)

  return ((Value.vmap.set "instance" instMap).set "order"
    (.list (order.map Value.str))).set "default" defOut

-- ---------------------------------------------------------------------
-- resolveOptions — §9.3's ten levels, and §9.4's merge directives
-- ---------------------------------------------------------------------

/-- §9.4: N is an integer of at least 1, and everything else is an
error.

`{"deep": 0}` is rejected DESPITE having an obvious reading, because
"replace at this key" already has a spelling and two spellings for one
behaviour is the defect class this repo exists to avoid. Without the
stated domain each port picks its own reading — reject, replace,
unlimited merge, or clamp to 1 — and the same document resolves
differently per language. -/
def checkShape (shape : Value) : PluginM Unit := do
  if !shape.isMap then return
  for k in shape.keys do
    let x := shape.get k
    if !(x.isMap && x.has "$MERGE") then continue
    let d := x.get "$MERGE"
    if d.isStr then
      let w := d.asStr
      if w == "replace" || w == "append" then continue
      raise "plugin_shape_invalid" ("invalid $MERGE directive at " ++ k ++ ": " ++ w)
        (details2 "key" (.str k) "directive" d)
    if d.isMap && d.has "deep" then
      let nv := d.get "deep"
      let n := nv.asNum
      if !nv.isNum || n != n.round || n < 1.0 then
        raise "plugin_shape_invalid"
          ("invalid $MERGE deep at " ++ k ++ ": " ++ Value.json nv)
          (details2 "key" (.str k) "directive" d)
      continue
    raise "plugin_shape_invalid"
      ("invalid $MERGE directive at " ++ k ++ ": " ++ Value.json d)
      (details2 "key" (.str k) "directive" d)

/-- The shape's non-directive values are the level-1 defaults. -/
private def defaultsOf (shape : Value) : Value :=
  if !shape.isMap then Value.vmap
  else (shape.keys).foldl
    (fun acc k =>
      let x := shape.get k
      if x.isMap && x.has "$MERGE" then acc else acc.set k x)
    Value.vmap

private def optsOf (src : Value) (key : String) : PluginM (Option Value) := do
  if src.isNull then return none
  -- The array form is equivalent to the map form (§9.1).
  if src.isList then
    for item in src.items do
      if (← canonRef (item.get "ref")) == key then
        return (if item.has "options" then some (item.get "options") else none)
    return none
  for k in src.keys do
    if (← canonRefS k) == key then
      let e := src.get k
      return (if e.has "options" then some (e.get "options") else none)
  return none

/-- Merge N levels below this key, replace below that. -/
private partial def deepTo (base over : Value) (n : Int) : Value :=
  if n ≤ 0 then over
  else if !(base.isMap && over.isMap) then over
  else
    (over.keys).foldl (fun acc k => acc.set k (deepTo (acc.get k) (over.get k) (n - 1)))
      ((base.keys).foldl (fun acc k => acc.set k (base.get k)) Value.vmap)

/-- Merge ONE layer onto the accumulator, honouring the shape's
directives. The directive holds at EVERY precedence level, not only
between document levels — §9.4 makes it a property of the shape, which
does not know which layer a value arrived from. -/
private partial def mergeOne (base over shape : Value) : Value :=
  if over.isNull then base
  else if !(base.isMap && over.isMap) then over
  else
    (over.keys).foldl
      (fun acc k =>
        let entry := if shape.isMap then shape.get k else .null
        let directive := if entry.isMap then entry.get "$MERGE" else .null
        let b := acc.get k
        let o := over.get k
        if directive.isStr && directive.asStr == "replace" then acc.set k o
        else if directive.isStr && directive.asStr == "append" then
          acc.set k (.list ((if b.isList then b.items else []) ++
            (if o.isList then o.items else [o])))
        else if directive.isMap && directive.has "deep" then
          acc.set k (deepTo b o ((directive.get "deep").asNum.toUInt64.toNat))
        -- Library default: deep for maps, REPLACE for lists.
        -- struct.merge is element-wise by index, which for option maps is
        -- nearly always wrong — ["a"] over ["x","y","z"] yielding
        -- ["a","y","z"] is the defect station hit on secrets.providers.
        else if b.isMap && o.isMap then acc.set k (mergeOne b o .null)
        else acc.set k o)
      ((base.keys).foldl (fun acc k => acc.set k (base.get k)) Value.vmap)

def resolveOptions (input : Value) : PluginM Value := do
  let shape := let s := input.get "shape"; if s.isMap then s else Value.vmap
  checkShape shape

  let r ← canonRef (input.get "ref")
  let name := refName r
  let doc := let d := input.get "doc"; if d.isMap then d else Value.vmap
  let profile := input.get "profile"
  let overlay := if profile.isStr then (doc.get "profile").get profile.asStr else .null
  let over := fun (k : String) => if overlay.isMap then overlay.get k else .null
  let some' := fun (v : Value) => if v.isNull then none else some v

  -- ONE ordered merge, lowest to highest. Levels 3-6 are not two
  -- namespaces collapsed separately and composed afterwards: that
  -- inverts the rule that PROFILE SPECIFICITY OUTRANKS DEFINITION
  -- SPECIFICITY, so a prod per-definition default would lose to a base
  -- instance value.
  let layers : List (Option Value) := [
    some (defaultsOf shape),                        -- 1
    some' (input.get "hostdefaults"),               -- 2
    ← optsOf (doc.get "default") name,              -- 3
    ← optsOf (doc.get "instance") r,                -- 4
    ← optsOf (over "default") name,                 -- 5
    ← optsOf (over "instance") r,                   -- 6
    some' (input.get "env"),                        -- 7
    some' (input.get "hostoptions"),                -- 8
    some' (input.get "loadoptions"),                -- 9
    some' (input.get "patch")                       -- 10
  ]
  return layers.foldl
    (fun acc l => match l with | none => acc | some x => mergeOne acc x shape) Value.vmap

end Plugin
