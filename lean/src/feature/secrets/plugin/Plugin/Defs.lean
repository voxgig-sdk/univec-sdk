-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lean/src/Plugin/Defs.lean)
-- Source: https://github.com/voxgig/plugin @ 48392f5e2b6d1434ee9b1a4a9a11f4480aaeb46a  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
import Plugin.Types

/-!
# The host's types, and the one thing Lean will not let us write

EVERY OTHER PORT GIVES A DEFINITION'S CALLBACK THE INSTANCE ITSELF.
`define(inst)`, and the instance points back at its host, and the host
holds a catalog of definitions. `c` opens that cycle with a forward
`typedef`, `ocaml` gathers it into `defs.ml`, `haskell` into `Defs.hs`.

**Lean's kernel refuses it.** A `Definition` holding
`Inst → PluginM Unit` puts `Inst` in a NEGATIVE position, and `Inst`
holds the `Definition` back, so the datatype occurs negatively in its
own definition:

    (kernel) arg #1 of '_nested.Option_2.some' has a non positive
    occurrence of the datatypes being declared

That is not a Lean quirk to route around; it is the logic refusing a
type whose inhabitants could encode a fixed point of `X → X`. Routing
around it with `unsafe` or an opaque cast would throw away the one thing
this language is for.

SO THE INSTANCE API IS AN EXPLICIT RECORD OF CLOSURES, and the cycle
never forms:

    HostApi   ← mentions nothing recursive
    InstApi   ← mentions HostApi, String, Value, PluginM
    Definition← mentions InstApi
    InstState ← mentions HostApi (for a nested host)
    HostState ← mentions Definition and InstState

Nothing points back. **And the shape is not a compromise**: §6 says a
plugin never mutates the host, it declares bindings and captures
resources through a small API. `InstApi` is that API, written down.
Lean made explicit what the other ports leave implicit in a pointer.

The one place it shows: `nest` takes no options and returns a `HostApi`
rather than a whole host, so the inner host SHARES the outer's catalog
and points. §10.1 already permits a shared catalog ("a catalog may be
shared between hosts"), and the driver's nested host wants exactly the
outer's probes, so the corpus cannot tell the difference.
-/

namespace Plugin

/-- What a nested host exposes to the plugin that nested it (§6.5). Just
enough for the outer instance to drive it; not a whole host, because a
whole host would mention `Definition` and close the cycle. -/
structure HostApi where
  ready : String → PluginM Unit
  list : PluginM Value
  -- `Inhabited` because `instApi` and `instNest` sit in a `partial`
  -- mutual block, and Lean will only compile a `partial` definition
  -- whose result type it knows is non-empty.
  deriving Inhabited

/-- The instance api, as a definition's callbacks see it. A record of
closures rather than a pointer to the instance — see the module note. -/
structure InstApi where
  ref : String
  name : String
  tag : String
  getOptions : PluginM Value
  getState : PluginM Value
  setState : Value → PluginM Unit
  bindHook : String → (Value → PluginM (Option Value)) → Value → PluginM Unit
  bindChain : String → ((Value → PluginM Value) → Value → PluginM Value) → Value → PluginM Unit
  exportValue : String → Value → PluginM Unit
  provides : Value → PluginM Unit
  /-- Answers a handle a plugin can hand back early. The scope still
  holds the entry and unwinding it twice is a no-op — releasing early
  must not make teardown wrong. -/
  acquire : PluginM Nat
  giveback : Nat → PluginM Unit
  release : Option (PluginM Unit) → PluginM Unit
  position : String → PluginM Value
  nest : PluginM HostApi
  /-- Only §5.2's reentrancy probe needs this: a transition attempted
  from inside a lifecycle callback. -/
  activateSelf : PluginM Unit
  deriving Inhabited

/-- A DEFINITION IS DATA WITH FUNCTIONS IN IT, not a class to extend. A
document could produce one, which is the property that makes a catalog a
data structure rather than a compile-time registry. -/
structure Definition where
  name : String
  shape : Value := .null
  define : Option (InstApi → PluginM Unit) := none
  activate : Option (InstApi → PluginM Unit) := none
  deactivate : Option (InstApi → PluginM Unit) := none
  close : Option (InstApi → PluginM Unit) := none
  reconfigure : Option (InstApi → Value → Value → PluginM Unit) := none

/-- A hook or provider binding. A binding answers with an `Option`:
`none` DECLINES, `some v` answers. `bail` needs the distinction and `c`
reaches it with a NULL pointer; here it is the type. -/
structure Bound where
  ref : String
  point : String
  /-- `provider` ranks by HIGHEST band, unlike hook and chain which run
  lowest first. Kept as declared so the two rules stay visibly different
  rather than one being derived from the other by a reader who then gets
  it backwards. -/
  band : Float := 0.0
  hook : Option (Value → PluginM (Option Value)) := none
  chain : Option ((Value → PluginM Value) → Value → PluginM Value) := none

/-- A scope entry. `acquire` hands back its index so a plugin can
release early; the scope keeps the entry, and unwinding it twice is a
no-op. -/
structure ScopeEntry where
  fn : Option (PluginM Unit) := none
  done : IO.Ref Bool
  /-- `acquire` and `release` both count toward `open`; a nested host's
  teardown does NOT — a teardown is not an acquisition, and the inner
  host keeps its own counter (`nest/open`). -/
  counts : Bool := true

structure InstState where
  ref : String
  defName : String
  seq : Float
  status : IO.Ref String
  pos : IO.Ref Float
  options : IO.Ref Value
  state : IO.Ref Value
  order : IO.Ref Value
  /-- §11.4's ALWAYS-RELUCTANT rebinding, made concrete: the provider
  ref this instance's activation actually selected, per requirement
  name. Recomputing the best candidate on every question silently
  re-points a live consumer at any better-ranked newcomer, and then
  losing the provider it was really using does not restart it. -/
  selected : IO.Ref Value
  /-- §9.6's `active: false`. THE BAR OUTLIVES THE APPLY THAT SET IT: a
  flag consulted only while `apply` ran let a later direct `ready` bring
  the instance live, which is the config switch it exists to be silently
  ignored. -/
  barred : IO.Ref Bool
  unmet : IO.Ref Value
  scope : IO.Ref (List ScopeEntry)
  /-- Declared in `define`, inserted only when activation SUCCEEDS
  (§8.1). Holding them until then is what makes a failed activate leave
  nothing behind. -/
  bindings : IO.Ref (List Bound)
  inner : IO.Ref (Option HostApi)
  /-- Declared in `define`, and VISIBLE while merely `loaded` (§11):
  they are data, and hiding them would make the loaded state useless for
  introspection. -/
  exports : IO.Ref Value
  provides : IO.Ref Value

structure HostState where
  catalog : IO.Ref (List Definition)
  reserved : Value
  keys : Value
  defaults : Value
  profile : Value
  points : Value
  bases : List (String × (Value → PluginM Value))
  /-- §11.3. `restart` (the default) treats provider replacement as an
  ordinary runtime operation. `hold` is the strict reading —
  deactivating a required instance is `plugin_dependency_held`. NOT the
  default, because a station that cannot swap a provider without a
  restart has lost the argument for having a plugin system. -/
  dependency : String
  /-- Set for the duration of a bulk teardown, so `held` knows this is a
  coordinated operation rather than an ad-hoc deactivation. -/
  coordinated : IO.Ref Bool
  instances : IO.Ref (List InstState)
  log : IO.Ref Value
  events : IO.Ref Value
  seqn : IO.Ref Float
  open_ : IO.Ref Float
  intransition : IO.Ref Bool
  /-- WHICH callback is running, not merely that one is. §8.1 puts
  resource capture in `activate` and §8.3 says `release` outside
  `activate` is `plugin_release_scope` — and a boolean alone cannot tell
  `activate` from `define`, so it admitted an acquire in `define` whose
  scope `unload` would never unwind. -/
  phase : IO.Ref String

structure HostOptions where
  catalog : Option (IO.Ref (List Definition)) := none
  reserved : Value := .null
  keys : Value := .null
  defaults : Value := .null
  profile : Value := .null
  points : Value := .null
  bases : List (String × (Value → PluginM Value)) := []
  dependency : String := ""

structure DeclareSpec where
  definition : String := ""
  options : Option Value := none
  order : Value := .null
  pos : Option Float := none
  tag : String := ""
  /-- §9.1: set ONLY by `hostdeclare` — "the host declares those
  instances itself, after the user merge, and always wins". -/
  hostOwned : Bool := false

end Plugin
