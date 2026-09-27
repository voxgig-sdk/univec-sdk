-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lean/src/Sekreto/Chain.lean)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/-
The secrets facade: a chain of providers plus a cache.

A Sekreto is an ordered chain of providers. `get` asks each in turn and
returns the first hit, so an app can be configured from environment
variables in development and a vault in production without changing a
line of its own code.

EVERY CONFIGURED PROVIDER IS A voxgig/plugin INSTANCE, addressed by
name+tag: `kind` for a store named after its kind and `kind$store`
otherwise, so `Sekreto.instances` reads like the chain. plugin owns the
catalog, the instances and the lifecycle; sekreto owns the walk, because
`lookup` is inherently asynchronous and voxgig/plugin has no async
surface to compose it with.

A chain may name only the four built-in kinds and whatever definitions
the calling project passed in `Options.plugins`. That is what keeps an
app whose chain is `[dotenv, env]` from linking AWS request signing and
seven HTTP vault clients.

A port of typescript/src/Sekreto.ts, which is canonical.
-/

import Sekreto.Text
import Sekreto.Json
import Sekreto.Core
import Sekreto.Provider
import Sekreto.Builtin

namespace Sekreto

/-- The store name a live provider answers to when nothing says
otherwise.

`describe` opens with the provider's kind - `hashicorp:...`,
`dotenv:...`, plain `env` - so the kind is the natural default, and a
custom provider gets a sensible name without implementing anything
extra. A spec'd provider's store is its `name` or its `kind`, decided
before the provider exists. -/
def storename (provider : Provider) : String :=
  takeWhile provider.describe (fun ch => ':' != ch)

/-- One provider in the chain, under the store name it answers to, and
the ref of the plugin instance that built it - `""` for a live provider
handed in directly, which no instance backs. -/
structure Entry where
  store : String
  ref : String
  provider : Provider

/-- One resolved value, with the store it came from. -/
structure Cached where
  store : String
  name : String
  value : String

/-- What a chain is made of. `providers` is the chain in resolution
order; `plugins` is the provider kinds beyond the built-ins that it may
name. Static and explicit: the calling project imports the plugins it
needs and passes them here, and a kind it did not pass is unknown to this
Sekreto. -/
structure Options where
  providers : List ProviderSpec := []
  plugins : List Plugin.Definition := []
  cache : Bool := true

/-- The catalog's names, sorted - what the unknown-kind message lists. -/
def catalognames (catalog : List Plugin.Definition) : List String :=
  Plugin.Value.sortWith Plugin.Value.strLe (catalog.map (·.name))

/-- The message for a kind the catalog does not hold.

A kind sekreto has never heard of is a typo; a kind that exists as a
plugin but was not passed in is the split working as designed and telling
you what to pass. Collapsing the two was the first thing that made the
split confusing to use. -/
def unknownkind (kind : String) (catalog : List Plugin.Definition) : String :=
  "sekreto: unknown provider kind: " ++ kind ++
  " (available: " ++ String.intercalate ", " (catalognames catalog) ++ ")" ++
  (if PLUGINKINDS.contains kind then
    " - " ++ kind ++ " is a sekreto plugin, not built in: pass it in the plugins option"
   else "")

/-- Run one plugin operation, and put its failure into this library's
terms.

A `SekretoError` that crossed the boundary comes back out as ITSELF, byte
for byte: `providerplugin` put it under `ERROR_CODE` with the message as
`cause`, and this is the one place that takes it off again. Anything else
is not sekreto's to rewrite and surfaces as the host worded it. -/
def runplugin {α : Type} (act : Plugin.PluginM α) : IO α := do
  match ← act.run with
  | .ok value => return value
  | .error err =>
    let cause := err.details.get "cause"
    if ERROR_CODE == err.code && cause.isStr then fail cause.asStr else fail err.message

end Sekreto

/-- The secrets facade: a chain of providers plus a cache.

Two ways to read. `get` is transparent - it walks the chain and takes the
first hit, and the caller never learns which store answered. `getfrom` is
directed - it names the store, and only that store is asked. Use the
first for ordinary configuration, the second when *which* store holds a
secret is part of what you mean.

There is no `Repr`, `ToString` or `deriving` anywhere on this structure,
and there cannot be one: most of its fields are `IO.Ref`, which has no
printer in Lean at all. So the hazard every other port answers with a
hand-written print hook - `print(sekreto)` emitting every resolved secret
- does not exist here; `Sekreto.inspect` is offered because the ports
agree on the shape, not because anything would otherwise leak. -/
structure Sekreto where
  /-- The voxgig/plugin host every spec'd provider is an instance of.
  Read it for introspection - `Sekreto.instances` names each store's ref
  and status - and nothing on it advances the chain. -/
  host : Plugin.HostState
  /-- The definitions this Sekreto can build: the built-ins, then what
  `Options.plugins` handed in. -/
  catalog : IO.Ref (List Plugin.Definition)
  /-- The chain, in resolution order. A ref, so `close` can empty it. -/
  entries : IO.Ref (List Sekreto.Entry)
  /-- Resolved values, keyed by (store, name). A LIST, not a map: the
  store a value came from stays attached, and redaction order does not
  vary between runs. -/
  cache : IO.Ref (List Sekreto.Cached)
  /-- Every value ever resolved, for `redactText`. Kept independently of
  the read cache, so `cache := false` does not silently disable
  redaction; append-only for the object's life, so neither `refresh` nor
  `close` forgets a secret that has already been handed out. -/
  seen : IO.Ref (List String)
  docache : Bool

namespace Sekreto

/-- An empty host over a catalog of its own. -/
private def freshhost (definitions : List Plugin.Definition)
    : IO (Plugin.HostState × IO.Ref (List Plugin.Definition)) := do
  let catalog ← IO.mkRef ([] : List Plugin.Definition)
  let host ← runplugin (Plugin.makeHost { catalog := some catalog })
  -- Built-ins first, then the plugins, into one catalog: `hostDefine`
  -- replaces a definition of the same name, which is how a plugin
  -- naming a built-in kind substitutes for it.
  for definition in definitions do
    runplugin (Plugin.hostDefine host definition)
  return (host, catalog)

/-- Build a chain from live providers, with no plugin instances behind
them. `names` is positional; an entry left `none` or empty falls back to
the provider's kind.

The host is empty and stays empty - a live provider is a chain entry with
no instance - and it is here so that `close` and `instances` mean the same
thing whichever way the chain was built. -/
def make (providers : List Provider) (names : List (Option String) := [])
    (cache : Bool := true) : IO Sekreto := do
  let (host, catalog) ← freshhost []
  let entries := (List.range providers.length).map (fun index =>
    let provider := providers.getD index { lookup := fun _ => pure none, describe := "" }
    let named := (names[index]?).join.filter (fun value => !value.isEmpty)
    ({ store := named.getD (storename provider), ref := "", provider := provider } : Entry))
  return {
    host := host, catalog := catalog,
    entries := ← IO.mkRef entries,
    cache := ← IO.mkRef [],
    seen := ← IO.mkRef [],
    docache := cache }

/-- One chain entry, as a plugin instance.

The instance is `kind` for a store named after its kind and `kind$store`
otherwise - `hashicorp$prod` - so `instances` reads like the chain. A
store name that is already taken gets a numbered tag from the host
instead, because two providers MAY share a store name (a directed read
walks both) and an instance ref may not. -/
private def declare (host : Plugin.HostState) (catalog : IO.Ref (List Plugin.Definition))
    (spec : ProviderSpec) : IO Entry := do
  let definitions ← catalog.get

  if !definitions.any (fun definition => spec.kind == definition.name) then
    fail (unknownkind spec.kind definitions)

  let store := if spec.name.isEmpty then spec.kind else spec.name

  if !Plugin.checktag (.str store) then
    fail ("sekreto: invalid store name: " ++ store)

  let wanted ←
    if store == spec.kind then pure spec.kind
    else runplugin (Plugin.formatRef (.str spec.kind) (.str store))

  let ref ←
    match ← runplugin (Plugin.hostInstance host wanted) with
    | none => pure wanted
    | some _ => runplugin (Plugin.autoTag host spec.kind)

  -- `load` runs the definition's `define`, which builds the provider from
  -- the spec; `activate` takes the instance live. Nothing is contacted by
  -- either: a provider opens nothing until its first lookup.
  let _ ← runplugin (Plugin.hostLoad host ref { options := some (optionsof spec) })
  let _ ← runplugin (Plugin.hostActivate host ref)

  match ← runplugin (Plugin.hostExports host (ref ++ "/" ++ PROVIDER_EXPORT)) with
  | some (.num slot) =>
    match ← slottake slot.toUInt64.toNat with
    | some provider => return { store := store, ref := ref, provider := provider }
    | none => fail ("sekreto: plugin " ++ spec.kind ++ " exported no provider")
  | _ => fail ("sekreto: plugin " ++ spec.kind ++ " exported no provider")

/-- Make a Sekreto from declarative provider specs - the same shape the
shared spec and an app's config file use.

Eager, in chain order, and it may refuse: an unknown kind, an unusable
store name, and `hashicorp`'s KV version are all decided here, before
anything is looked up. Construction contacts nothing; the first network
call is the first lookup. -/
def sekreto (options : Options) : IO Sekreto := do
  let (host, catalog) ← freshhost (BUILTINS ++ options.plugins)
  let mark ← slotseq.get

  let entries ← tryCatch (do
      let mut built : List Entry := []
      for spec in options.providers do
        built := built ++ [← declare host catalog spec]
      return built)
    (fun err => do
      -- A chain that could not be finished leaves nothing behind: the
      -- host closes, and any provider a `define` parked is dropped.
      let _ ← tryCatch (runplugin (Plugin.hostClose host)) (fun _ => pure ())
      slotdrop mark
      throw err)

  return {
    host := host, catalog := catalog,
    entries := ← IO.mkRef entries,
    cache := ← IO.mkRef [],
    seen := ← IO.mkRef [],
    docache := options.cache }

/-- The single path both readers share.

The order matters and every step of it is pinned by the corpus: the name
is validated FIRST, before the cache and before the first provider; a
cache hit does NOT push to `seen`; the EMPTY STRING IS A HIT; misses are
never cached; and `seen` is appended to whether caching is on or off. A
provider that throws is not caught - the failure propagates out of
`get`. -/
private def resolve (self : Sekreto) (store name : String)
    (useentries : List Entry) : IO (Option String) := do
  let _ ← ofResult (checkname name)

  let held ← self.cache.get
  let hit := if self.docache then
      held.find? (fun entry => store == entry.store && name == entry.name)
    else none

  match hit with
  | some entry => return some entry.value
  | none =>
    let rec walk (rest : List Entry) : IO (Option String) := do
      match rest with
      | [] => return none
      | entry :: more =>
        match ← entry.provider.lookup name with
        | some value => return some value
        | none => walk more

    match ← walk useentries with
    | none => return none
    | some value =>
      if self.docache then
        self.cache.modify (fun held => held ++ [{ store := store, name := name, value := value }])
      self.seen.modify (fun held => held ++ [value])
      return some value

/-- The secret, or `none` if no provider has it. Named `tryget` because
`try` is a Lean keyword. -/
def tryget (self : Sekreto) (name : String) : IO (Option String) := do
  resolve self "" name (← self.entries.get)

/-- The secret, or a refusal if no provider has it. -/
def get (self : Sekreto) (name : String) : IO String := do
  match ← self.tryget name with
  | some value => return value
  | none => fail ("sekreto: unknown secret: " ++ name)

/-- The secret from one named store, or `none` if that store does not
have it.

Naming a store that is not in the chain is an error, not a miss, and it
is checked BEFORE the name: `tryget` already means "this store may not
have it", so it cannot also mean "this store may not exist" without
hiding a typo. Store names may repeat, and a directed read walks every
matching entry in chain order. -/
def tryfrom (self : Sekreto) (store name : String) : IO (Option String) := do
  let entries ← self.entries.get
  let matching := entries.filter (fun entry => store == entry.store)
  if matching.isEmpty then fail ("sekreto: unknown store: " ++ store)
  resolve self store name matching

/-- The secret from one named store, or a refusal if that store does not
have it. -/
def getfrom (self : Sekreto) (store name : String) : IO String := do
  match ← self.tryfrom store name with
  | some value => return value
  | none => fail ("sekreto: unknown secret: " ++ store ++ ":" ++ name)

/-- Does any provider have this secret? -/
def has (self : Sekreto) (name : String) : IO Bool := do
  return (← self.tryget name).isSome

/-- Does this named store have this secret? -/
def hasin (self : Sekreto) (store name : String) : IO Bool := do
  return (← self.tryfrom store name).isSome

/-- Every named secret at once, in the order asked. Missing ones are an
error, and the walk stops at the first. -/
def all (self : Sekreto) (names : List String) : IO (Pairs String) := do
  let mut out : Pairs String := []
  for name in names do
    out := out ++ [(name, ← self.get name)]
  return out

/-- A description of each provider, in resolution order, repeats kept. -/
def sources (self : Sekreto) : IO (List String) := do
  return (← self.entries.get).map (fun entry => entry.provider.describe)

/-- The name of each store `getfrom` can address, in resolution order and
without repeats. -/
def stores (self : Sekreto) : IO (List String) := do
  let entries ← self.entries.get
  return (entries.map (fun entry => entry.store)).eraseDups

/-- Every plugin instance behind the chain, ref to status, sorted by ref
- what `host.list()` answers in the other ports. -/
def instances (self : Sekreto) : IO (Pairs String) := do
  let listed ← runplugin (Plugin.hostList self.host)
  return (listed.keys).map (fun ref => (ref, (listed.get ref).asStr))

/-- The kinds this Sekreto can build, sorted. -/
def kinds (self : Sekreto) : IO (List String) := do
  return catalognames (← self.catalog.get)

/-- Replace every value this Sekreto has resolved with `[redacted]`.

Named `redactText` because the module-level `redact` this delegates to
keeps its own name; the zig port made the same split for the same
reason. Works whether or not caching is enabled. -/
def redactText (self : Sekreto) (text : String) : IO String := do
  return redact text (← self.seen.get)

/-- Drop cached values, so the next `get` asks the providers again.
`seen` is untouched: redaction must not forget a secret already handed
out. -/
def refresh (self : Sekreto) : IO Unit := self.cache.set []

/-- Tear the chain down: every plugin instance is deactivated and
unloaded, in reverse, releasing whatever a provider acquired at
activation. Afterwards `stores` and `sources` are empty, `tryget` misses
and `get` refuses - and `redactText` still knows every value ever
resolved. -/
def close (self : Sekreto) : IO Unit := do
  runplugin (Plugin.hostClose self.host)
  self.entries.set []
  self.cache.set []

/-- What a printer would be allowed to say. Never reaches a value. -/
def inspect (self : Sekreto) : IO String := do
  return "Sekreto { stores: [ " ++ String.intercalate ", " (← self.stores) ++ " ] }"

end Sekreto
