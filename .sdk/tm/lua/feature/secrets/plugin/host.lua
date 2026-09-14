-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lua/src/plugin/host.lua)
-- Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- The host: the lifecycle state machine (section 5), extension points
-- (section 6), and resource capture (section 8).
--
-- TWO RULES SHAPE EVERY METHOD BELOW.
--
-- Transitions are SEQUENTIAL (section 5.2). One at a time, in call order,
-- never interleaved; a transition triggered from inside a lifecycle
-- callback is `plugin_reentrant`. A hard rule, because it is the only way
-- the semantics can be identical in Go, in Lua and in single-threaded
-- JavaScript.
--
-- Reconciliation is EAGER (section 18's portability budget). A transition
-- settles by running the state machine to a fixed point, not by suspending
-- on a promise.
--
-- A LUA TABLE HAS NO ORDER. Every walk of the registry here sorts its keys
-- first: `T.keys` is not tidiness, it is the difference between a
-- deterministic teardown and one that changes between runs.

local T = require 'feature.secrets.plugin.types'
local R = require 'feature.secrets.plugin.ref'
local Cat = require 'feature.secrets.plugin.catalog'
local Ord = require 'feature.secrets.plugin.order'
local Pt = require 'feature.secrets.plugin.point'
local Ex = require 'feature.secrets.plugin.export'
local Cap = require 'feature.secrets.plugin.capability'
local Cfg = require 'feature.secrets.plugin.config'
local Dep = require 'feature.secrets.plugin.depend'

local M = {}

-- ------------------------------------------------------------------
-- Inst - what a definition's callbacks see
-- ------------------------------------------------------------------
--
-- Deliberately not the internal record: a plugin that could reach `status`
-- could also write it.

local Inst = {}
Inst.__index = Inst
M.Inst = Inst

function Inst.new(host, entry)
  local parsed = R.parse_ref(entry.ref)
  return setmetatable({
    host = host,
    entry = entry,
    ref = entry.ref,
    name = parsed.name,
    tag = parsed.tag,
  }, Inst)
end

-- The resolved options and the instance's own state, both LIVE: a lua
-- table is a reference, so a callback that keeps one sees what `apply` and
-- `options` write into it.
function Inst:options()
  return self.entry.options
end

function Inst:state()
  return self.entry.state
end

-- Foreign resources the host did not hand out are registered explicitly
-- (section 8.3); host calls are recorded automatically.
--
-- SYMMETRIC WITH `acquire`, and it has to be: `open` counts the resources
-- CURRENTLY HELD, so an entry that is registered and then unwound must
-- leave the count where it found it.
function Inst:release(fn)
  -- Section 8.3: "`inst.release` outside `activate` is
  -- `plugin_release_scope`". A flag saying merely that a transition is
  -- running is true in `define` too, and a scope entry registered there is
  -- never unwound.
  if 'activate' ~= self.host.phase then
    T.fail('plugin_release_scope', 'release called outside activate', nil)
  end
  local host = self.host
  local done = false
  table.insert(self.entry.scope, function()
    if done then return end
    done = true
    host.open = host.open - 1
    fn()
  end)
  host.open = host.open + 1
end

-- The synthetic counter the driver owns, so "what is open" is data rather
-- than an assertion each port words differently.
--
-- Returns its own release, so a plugin can hand one back early. The scope
-- still holds the entry and unwinding it twice is a no-op - releasing
-- early must not make teardown wrong.
function Inst:acquire()
  -- Section 8.1: resources are "acquired during `activate` - the scope's
  -- actual job". Same reason as `release` above.
  if 'activate' ~= self.host.phase then
    T.fail('plugin_release_scope', 'acquire called outside activate', nil)
  end
  local host = self.host
  local done = false
  local rel = function()
    if done then return end
    done = true
    host.open = host.open - 1
  end
  table.insert(self.entry.scope, rel)
  host.open = host.open + 1
  return rel
end

-- Bind into a host point. Declared in `define`; the host inserts it only
-- after `activate` returns successfully (section 8.1), which is why a
-- failing activate leaves no live binding behind.
function Inst:bind(point, fn, band)
  -- Section 12 has carried `plugin_bind_scope` - "binding declared outside
  -- `define`" - since before anything raised it. Section 8.1 puts binding
  -- DECLARATION in `define` and INSERTION at a successful activate, and
  -- the guard was the half nobody wrote.
  if 'define' ~= self.host.phase then
    T.fail('plugin_bind_scope', 'bind called outside define: ' .. point,
           T.map { ref = self.ref, point = point })
  end
  if not T.has(self.host.points, point) then
    T.fail('plugin_point_unknown', 'no such point: ' .. point,
           T.map { point = point })
  end
  table.insert(self.entry.bindings, {
    ref = self.ref,
    point = point,
    fn = fn,
    band = 'integer' == math.type(band) and band or 0,
  })
end

-- Published for other plugins and for the application (section 11).
function Inst:export(key, value)
  self.entry.exports[key] = value
  self.entry.exportkeys[key] = true
end

-- What this instance can do for others (section 11.1).
function Inst:provides(prov)
  table.insert(self.entry.provides, prov)
end

-- Where this binding landed (section 6.6) - the plugin-side counterpart to
-- a host pin. THE HOST DOES NOT POLICE THIS; it just makes the fact
-- available.
function Inst:position(point)
  return self.host:positionof(self.ref, point)
end

-- AN INSTANCE MAY ITSELF BE A HOST (section 6.5), and THE OUTER ONE OWNS
-- THE INNER ONE'S LIFETIME. Registering the teardown in the instance scope
-- is what makes that true rather than aspirational.
function Inst:nest(nestopts)
  if not self.host.transition then
    T.fail('plugin_release_scope', 'nest called outside a lifecycle callback',
           nil)
  end
  local inner = M.make_host(nestopts)
  table.insert(self.entry.scope, function() inner:close() end)
  self.entry.inner = inner
  return inner
end

-- ------------------------------------------------------------------
-- Host
-- ------------------------------------------------------------------

local Host = {}
Host.__index = Host
M.Host = Host

function M.make_host(options)
  options = options or T.map {}
  return setmetatable({
    opts = options,
    dependency = T.getv(options, 'dependency') or 'restart',
    reserved = T.getv(options, 'reserved') or T.list {},
    points = T.getv(options, 'points') or T.map {},
    catalog = T.getv(options, 'catalog') or Cat.make_catalog {},
    inst = {},
    order_of = {},          -- refs, kept sorted, so every walk is stable
    log = {},
    -- Section 14: the lifecycle event record. `seq` distinguishes ONE
    -- INCARNATION of stripe$test from the next, which is the whole reason
    -- it is not `pos` (section 4 rule 4).
    events = {},
    seqn = 0,
    open = 0,
    transition = false,
    -- WHICH callback is running, not merely that one is. Section 8.1 puts
    -- resource capture in `activate` and 8.3 says `release` outside
    -- `activate` is `plugin_release_scope` - and a bare flag cannot tell
    -- `activate` from `define`, so it admitted an acquire in `define`
    -- whose scope `unload` would never unwind.
    phase = nil,
    coordinated = false,
  }, Host)
end

-- The registry's refs, sorted. Lua tables have no order, so this is the
-- one walk every method uses.
function Host:refs()
  local out = {}
  for k in pairs(self.inst) do out[#out + 1] = k end
  table.sort(out)
  return out
end

function Host:define(definition)
  self.catalog:add(definition)
end

-- --- observation ------------------------------------------------

-- Introspection NEVER advances the state (section 5.2). A status page must
-- not be a way to accidentally import twenty packages.
function Host:list()
  local out = T.map {}
  for _, ref in ipairs(self:refs()) do
    out[ref] = self.inst[ref].status
  end
  return out
end

-- The instance record, or nil when nothing is registered under that ref.
-- THE REF IS VALIDATED, not merely canonicalized: looking an instance up
-- by `"bad name"` is `plugin_bad_name`, not a quiet miss.
function Host:instance(ref)
  return self.inst[R.canon_ref(ref)]
end

function Host:trace()
  local out = {}
  for i, e in ipairs(self.events) do out[i] = e end
  return T.list(out)
end

function Host:observable(result)
  local log = {}
  for i, l in ipairs(self.log) do log[i] = l end
  return T.map {
    status = self:list(),
    open = self.open,
    log = T.list(log),
    result = nil == result and T.NULL or result,
  }
end

-- --- the state machine ------------------------------------------

function Host:guard()
  if not self.transition then return end
  T.fail('plugin_reentrant',
         'transition attempted from inside a lifecycle callback', nil)
end

function Host:need(ref)
  local r = R.canon_ref(ref)
  local entry = self.inst[r]
  if nil == entry then
    T.fail('plugin_not_loaded', 'no such instance: ' .. r, T.map { ref = r })
  end
  return entry
end

function Host:checkreserved(ref)
  if 0 == T.len(self.reserved) then return end
  local name = R.refname(ref)
  for i = 1, T.len(self.reserved) do
    if self.reserved[i] == name then
      T.fail('plugin_ref_reserved', 'ref is reserved by the host: ' .. ref,
             T.map { ref = ref })
    end
  end
end

function Host:run(entry, callback, at)
  local fn = entry.def[callback]
  table.insert(self.log, entry.ref .. ':' .. at)
  table.insert(self.events, T.map {
    ref = entry.ref, event = at, seq = entry.seq, status = entry.status,
  })
  if 'function' ~= type(fn) then return end

  self.transition = true
  self.phase = at
  local ok, err = pcall(fn, Inst.new(self, entry))
  self.transition = false
  self.phase = nil
  if ok then return end

  -- Section 12: `plugin_define_failed` and its three siblings are "a
  -- callback raised; wraps the cause". AN ERROR THAT ALREADY CARRIES A
  -- CODE KEEPS IT - the code is the error's identity, and a plugin raising
  -- `store_unreachable` must not have it rewritten. Only a code-less error
  -- is wrapped.
  if '' ~= T.codeof(err) then error(err, 0) end

  T.fail('plugin_' .. at .. '_failed',
         entry.ref .. ' raised in ' .. at .. ': ' .. T.message(err),
         T.map { ref = entry.ref, cause = T.message(err) })
end

-- AUTO-TAGGING IS EXPLICIT (section 4 rule 3). `declare('stripe', {tag =
-- '?'})` assigns the LOWEST UNUSED POSITIVE INTEGER tag and returns the
-- assigned pair. Without `'?'`, a collision is an error.
function Host:autotag(name)
  local n = 1
  while true do
    local cand = R.format_ref(name, tostring(n))
    if nil == self.inst[cand] then return cand end
    n = n + 1
  end
end

function Host:count()
  local n = 0
  for _ in pairs(self.inst) do n = n + 1 end
  return n
end

function Host:declare(ref, spec)
  spec = spec or T.map {}
  if '?' == T.getv(spec, 'tag') then
    ref = self:autotag(R.refname(R.canon_ref(ref)))
  end
  local r = R.canon_ref(ref)
  if not T.truthy(T.getv(spec, 'hostowned')) then
    self:checkreserved(r)
  end
  local defname = T.getv(spec, 'definition') or R.refname(r)
  local definition = self.catalog:get(defname)
  if nil == definition then
    T.fail('plugin_unknown_definition', 'not in catalog: ' .. defname,
           T.map { name = defname })
  end

  local existing = self.inst[r]
  if nil ~= existing then
    -- Section 4 rule 1: a pair addresses at most one instance.
    -- Re-declaring the SAME definition is the idempotent case; a different
    -- one is a duplicate, not a silent overwrite (seneca) and not an
    -- impossibility (sdkgen).
    if existing.def.name ~= definition.name then
      T.fail('plugin_ref_duplicate', 'instance already declared: ' .. r,
             T.map { ref = r })
    end
    return existing
  end

  local pos = T.getv(spec, 'pos')
  local entry = {
    ref = r,
    def = definition,
    status = 'declared',
    pos = nil == pos and self:count() or pos,
    seq = self.seqn,
    options = T.getv(spec, 'options') or T.map {},
    state = T.map {},
    order = T.getv(spec, 'order'),
    unmet = {},
    scope = {},
    -- Section 11.4's ALWAYS-RELUCTANT rebinding made concrete: the
    -- provider ref this instance's activation actually chose, per
    -- requirement name. Re-ranking on every question silently re-points a
    -- live consumer at any better newcomer, and then losing the provider
    -- it was really using does not restart it.
    selected = {},
    bindings = {},
    exports = T.map {},
    exportkeys = {},
    provides = {},
    inner = nil,
    barred = false,
  }
  self.seqn = self.seqn + 1
  self.inst[r] = entry
  return entry
end

-- Section 9.1: a host that reserves a name MUST still be able to declare
-- the instance it reserved - "The host declares those instances itself,
-- after the user merge, and always wins."
--
-- THE BOUNDARY IS BY METHOD, NOT BY CALLER, and that is a real limit: no
-- language here can tell the embedding host from a plugin holding the same
-- host object. What reservation protects is CONFIGURATION - documents,
-- overlays, `VOXGIG_PLUGIN_*`, construction options and ordinary
-- declare/load/options - and all of that still checks.
function Host:hostdeclare(ref, spec)
  self:guard()
  local owned = T.map {}
  for k, v in pairs(spec or T.map {}) do owned[k] = v end
  owned.hostowned = true
  return self:declare(ref, owned)
end

function Host:load(ref, spec)
  self:guard()
  spec = spec or T.map {}
  local entry = self:declare(ref, spec)
  if 'declared' ~= entry.status then return entry end  -- idempotent

  -- PRESENCE, NOT TRUTH: an empty options map must CLEAR what the instance
  -- was declared with.
  if T.has(spec, 'options') and T.NULL ~= spec.options then
    entry.options = spec.options
  end
  local ok, err = pcall(function() self:run(entry, 'define', 'define') end)
  if not ok then
    entry.status = 'failed'
    error(err, 0)
  end
  entry.status = 'loaded'

  -- AT LOAD, and before anything runs: a cycle through restart-causing
  -- requirements does not settle, and the only safe time to report a
  -- non-terminating reconcile is before it starts (section 11.3).
  -- `provides` is populated by `define`, which has just run, so this is
  -- the first moment the graph is complete.
  ok, err = pcall(function() Dep.checkcycle(self:graphnodes()) end)
  if not ok then
    entry.status = 'failed'
    error(err, 0)
  end
  return entry
end

-- The requirement graph as plain data, for the pure detector.
function Host:graphnodes()
  local out = {}
  for _, ref in ipairs(self:refs()) do
    local entry = self.inst[ref]
    local provides = {}
    for _, p in ipairs(entry.provides) do
      provides[#provides + 1] = T.getv(p, 'name')
    end
    out[#out + 1] = {
      ref = ref,
      provides = provides,
      requires = Dep.requirements(entry.options),
    }
  end
  return out
end

function Host:activate(ref)
  self:guard()
  local entry = self:need(ref)
  if 'live' == entry.status then return entry end  -- no-op, success

  if 'failed' == entry.status then
    T.fail('plugin_bad_state', 'instance has failed: ' .. entry.ref,
           T.map { ref = entry.ref })
  end
  -- Section 9.6: `active: false` bars the instance from running, and the
  -- bar is on the INSTANCE rather than on the apply that set it. `ready`
  -- reaches this through `activate`, so one guard covers both verbs the
  -- design names.
  if entry.barred then
    T.fail('plugin_inactive',
           'instance is barred by active: false: ' .. entry.ref,
           T.map { ref = entry.ref })
  end
  if 'declared' == entry.status then
    self:load(entry.ref)
  end

  -- A declared requirement that is not live means `pending`: activation is
  -- a STANDING REQUEST, not a one-shot event.
  local unmet = self:unmetof(entry)
  if 0 < #unmet then
    entry.unmet = unmet
    entry.status = 'pending'
    return entry
  end

  local ok, err = pcall(function() self:run(entry, 'activate', 'activate') end)
  if not ok then
    -- Unwind whatever the partial activation captured, in reverse.
    self:unwind(entry)
    entry.status = 'failed'
    error(err, 0)
  end
  -- Section 11.4: THE SELECTION IS MADE HERE, once, and remembered. Every
  -- later question - the cascade, `hold`, `unmet` - reads it back rather
  -- than re-ranking, which is what "always-reluctant" means.
  for _, req in ipairs(Dep.requirements(entry.options)) do
    self:chosen(entry, req, true)
  end
  entry.status = 'live'
  self:reconcile()
  return entry
end

function Host:deactivate(ref)
  self:guard()
  local entry = self:need(ref)
  if 'loaded' == entry.status or 'declared' == entry.status then
    return entry
  end

  -- Section 5.2: `unload` is THE ONLY TRANSITION OUT OF `failed`.
  if 'failed' == entry.status then
    T.fail('plugin_bad_state', 'instance has failed: ' .. entry.ref,
           T.map { ref = entry.ref })
  end

  if 'pending' == entry.status then
    -- DEACTIVATING A PENDING INSTANCE RUNS NO CALLBACK (section 5.2). It
    -- never reached activate, so it holds no scope and no live bindings;
    -- running the definition's deactivate there would be teardown without
    -- matching setup, which plugins are not written to survive and which
    -- could fail an instance that had done nothing wrong. It cannot fail.
    entry.status = 'loaded'
    entry.unmet = {}
    return entry
  end

  self:held(entry.ref)
  self:cascade(entry.ref, {})

  local ok, err = pcall(function()
    self:run(entry, 'deactivate', 'deactivate')
  end)
  if not ok then
    self:unwind(entry)
    entry.status = 'failed'
    error(err, 0)
  end
  self:releasecheck(entry, self:unwind(entry))
  entry.status = 'loaded'
  self:reconcile()
  return entry
end

function Host:unload(ref)
  self:guard()
  local entry = self:need(ref)
  if 'live' == entry.status or 'pending' == entry.status then
    if 'live' == entry.status then
      self:held(entry.ref)
      self:cascade(entry.ref, {})
      local ok, err = pcall(function()
        self:run(entry, 'deactivate', 'deactivate')
      end)
      if not ok then
        -- Section 5.2: ANY failure during a transition lands the instance
        -- in `failed`, with the scope STILL FULLY UNWOUND - and the
        -- instance STAYS REGISTERED, because `failed` is a state an
        -- operator has to be able to see.
        self:unwind(entry)
        entry.status = 'failed'
        error(err, 0)
      end
      self:releasecheck(entry, self:unwind(entry))
    end
    entry.status = 'loaded'
  end
  if 'loaded' == entry.status or 'failed' == entry.status then
    local ok, err = pcall(function() self:run(entry, 'close', 'close') end)
    self.inst[entry.ref] = nil
    if not ok then error(err, 0) end
    return
  end
  self.inst[entry.ref] = nil
end

-- Runs the whole forward path in one call (section 5.1).
function Host:ready(ref)
  self:guard()
  local r = R.canon_ref(ref)
  if nil == self.inst[r] then self:declare(r) end
  if 'declared' == self.inst[r].status then self:load(r) end
  return self:activate(r)
end

-- Bindings go live only when activation succeeds (section 8.1), so the
-- teardown is the exact inverse: reverse order, always. Returns the errors
-- the scope raised. Section 8.3: "A failing release does not stop the
-- rest. Every entry runs, in reverse order, whatever any of them does; the
-- errors are collected and raised as one `plugin_release_failed`."
--
-- A selection belongs to ONE activation (section 11.4). Leaving `live` by
-- any door drops it, so the next activation ranks afresh - keeping it
-- would make a consumer prefer a provider it never actually ran against.
function Host:unwind(entry)
  entry.selected = {}
  local scope = entry.scope
  entry.scope = {}
  local errors = {}
  for i = #scope, 1, -1 do
    local ok, err = pcall(scope[i])
    if not ok then errors[#errors + 1] = err end
  end
  return errors
end

-- Section 8.3: "A failed release ends the instance in `failed`, exactly as
-- a failed callback does (5.2) - a release that raised may have leaked,
-- and an instance that may be holding resources it cannot account for must
-- not be reactivated."
function Host:releasecheck(entry, errors)
  if 0 == #errors then return end
  entry.status = 'failed'
  local causes = {}
  for _, e in ipairs(errors) do causes[#causes + 1] = T.message(e) end
  T.fail('plugin_release_failed',
         'release failed for ' .. entry.ref .. ': '
         .. table.concat(causes, '; '),
         T.map { ref = entry.ref, cause = T.list(causes) })
end

-- A REQUIREMENT IS ON A CAPABILITY, not on a ref (section 11.1). A bare
-- string is shorthand for `{name}`. A ref satisfies too, because a host
-- that genuinely needs a specific instance should not have to invent a
-- capability for it.
function Host:unmetof(entry)
  local out = {}
  for _, req in ipairs(Dep.requirements(entry.options)) do
    if Dep.gatesactivation(req) and 0 == #self:providersof(req) then
      out[#out + 1] = T.getv(req, 'name')
    end
  end
  return out
end

-- Section 11.4's always-reluctant selection, and the ONE place a provider
-- is picked for a live instance. If this instance already selected a
-- provider for `req` and that provider is STILL a candidate, it keeps it -
-- a better-ranked newcomer does not take it.
--
-- `remember` is false for the questions asked ABOUT an instance rather
-- than BY it: introspection must not create a binding.
function Host:chosen(entry, req, remember)
  local cands = self:providersof(req)
  if 0 == #cands then return nil end

  local name = T.getv(req, 'name')
  local held = entry.selected[name]
  if nil ~= held then
    for i = 1, #cands do
      if T.getv(cands[i], 'ref') == held then return held end
    end
  end

  local best = T.getv(cands[1], 'ref')
  if remember then entry.selected[name] = best end
  return best
end

function Host:boundproviders(entry)
  local out = {}
  local seen = {}
  for _, req in ipairs(Dep.requirements(entry.options)) do
    if Dep.restartsonloss(req) then
      local ref = self:chosen(entry, req, false)
      if nil ~= ref and not seen[ref] then
        seen[ref] = true
        out[#out + 1] = ref
      end
    end
  end
  return out
end

-- Live instances whose selected provider is `ref` and which would be
-- restarted by losing it.
function Host:consumersof(ref)
  local out = {}
  for _, r in ipairs(self:refs()) do
    local c = self.inst[r]
    if r ~= ref and 'live' == c.status then
      for _, p in ipairs(self:boundproviders(c)) do
        if p == ref then
          out[#out + 1] = r
          break
        end
      end
    end
  end
  return out
end

-- Section 11.3's `hold` asks a DIFFERENT question from the cascade, and
-- reading it off `consumersof` answered the cascade's.
--
-- The cascade wants the edges that RESTART - mandatory-static and
-- optional-static - because a restart is what it performs. `hold` says
-- "deactivating a REQUIRED instance is `plugin_dependency_held`", and
-- required is cardinality: `gatesactivation`, not `restartsonloss`. The
-- two sets differ in both directions and each difference was a real bug.
function Host:holdersof(ref)
  local out = {}
  for _, r in ipairs(self:refs()) do
    local c = self.inst[r]
    if r ~= ref and 'live' == c.status then
      for _, req in ipairs(Dep.requirements(c.options)) do
        if Dep.gatesactivation(req) and ref == self:chosen(c, req, false) then
          out[#out + 1] = r
          break
        end
      end
    end
  end
  return out
end

function Host:providersof(req)
  local name = T.getv(req, 'name')
  local want = R.canon(name)
  local cands = {}
  for _, ref in ipairs(self:refs()) do
    local target = self.inst[ref]
    if 'live' == target.status then
      -- A ref satisfies directly.
      if ref == want then
        cands[#cands + 1] = T.map {
          ref = ref, pos = target.pos, provides = T.map { name = name },
        }
      else
        for _, prov in ipairs(target.provides) do
          if T.same(T.getv(prov, 'name'), name) then
            cands[#cands + 1] = T.map {
              ref = ref, pos = target.pos, provides = prov,
            }
          end
        end
      end
    end
  end
  return Cap.resolve_capability(req, T.list(cands))
end

-- CONSUMERS GO DOWN FIRST, NOT AFTERWARDS (section 11.3).
--
-- The cascade is part of the provider's own deactivation and runs BEFORE
-- the provider's `deactivate` callback and scope unwind, so a consumer's
-- teardown can still call the thing it depends on - flushing a buffer to
-- the store it is about to lose is exactly what a `deactivate` callback is
-- for, and a cascade that fired after the provider was already gone would
-- make that impossible.
function Host:cascade(provider, seen)
  if seen[provider] then return end
  seen[provider] = true

  for _, r in ipairs(self:consumersof(provider)) do
    local consumer = self.inst[r]
    if nil ~= consumer and 'live' == consumer.status then
      self:cascade(r, seen)  -- deepest-first
      local ok = pcall(function()
        self:run(consumer, 'deactivate', 'deactivate')
      end)
      local errors = self:unwind(consumer)
      if not ok or 0 < #errors then
        -- Section 5.2: ANY failure during a transition lands the instance
        -- in `failed`. Marking it `pending` handed it straight back to
        -- `reconcile`, which would activate it again the moment the
        -- provider returned.
        consumer.status = 'failed'
      else
        consumer.status = 'pending'
        consumer.unmet = self:unmetof(consumer)
      end
    end
  end
end

-- The hold check is A GUARD ON AD-HOC DEACTIVATION, NOT ON COORDINATED
-- TEARDOWN. In a bulk operation that is removing the holders too -
-- `close`, or an `apply` plan whose own steps deactivate them - it is
-- suspended for exactly those holders, and the teardown still runs
-- consumers before providers.
function Host:held(ref)
  if 'hold' ~= self.dependency then return end
  if self.coordinated then return end

  local holders = self:holdersof(ref)
  if 0 == #holders then return end

  T.fail('plugin_dependency_held',
         'instance is required by live consumers: ' .. ref,
         T.map { ref = ref, holders = T.list(holders) })
end

-- EAGER reconciliation: run to a fixed point rather than scheduling.
--
-- Two directions, and both are the reason `pending` exists. Activation is
-- a STANDING REQUEST, not a one-shot event.
function Host:reconcile()
  local moved = true
  local rounds = 0
  while moved do
    moved = false
    rounds = rounds + 1
    if 1000 < rounds then break end

    -- Losses first, so a cascade settles in one pass rather than
    -- alternating with re-activations.
    for _, r in ipairs(self:refs()) do
      local entry = self.inst[r]
      if nil ~= entry and 'live' == entry.status then
        local lost = {}
        for _, q in ipairs(Dep.requirements(entry.options)) do
          if Dep.gatesactivation(q) and 0 == #self:providersof(q) then
            lost[#lost + 1] = q
          end
        end
        if 0 < #lost then
          -- POLICY IS PER REQUIREMENT, not per instance (section 11.3). A
          -- `dynamic` requirement whose provider is gone leaves the
          -- consumer LIVE and notified.
          local restarts = false
          for _, q in ipairs(lost) do
            if Dep.restartsonloss(q) then restarts = true break end
          end
          if restarts then
            local ok = pcall(function()
              self:run(entry, 'deactivate', 'deactivate')
            end)
            local errors = self:unwind(entry)
            if not ok or 0 < #errors then
              entry.status = 'failed'
            else
              entry.status = 'pending'
              entry.unmet = self:unmetof(entry)
            end
            moved = true
          end
        end
      end
    end

    for _, r in ipairs(self:refs()) do
      local entry = self.inst[r]
      if nil ~= entry and 'pending' == entry.status
          and 0 == #self:unmetof(entry) then
        local ok = pcall(function()
          self:run(entry, 'activate', 'activate')
        end)
        if ok then
          entry.status = 'live'
          entry.unmet = {}
        else
          self:unwind(entry)
          entry.status = 'failed'
        end
        moved = true
      end
    end
  end
end

-- --- ordering ---------------------------------------------------

function Host:order(point)
  -- Sorted by declaration SEQUENCE, which is what makes the section 7
  -- sort's fall-through deterministic in a language whose maps have no
  -- insertion order. Section 7 breaks ties by `pos`; two instances CAN
  -- share one - `declare` defaults `pos` to the registry size, so an
  -- unload followed by a fresh declare reuses a surviving instance's - and
  -- past that this was falling through to table order. `seq` is that
  -- order, made explicit.
  local live = {}
  for _, ref in ipairs(self:refs()) do
    local entry = self.inst[ref]
    if 'live' == entry.status then live[#live + 1] = entry end
  end
  live = T.stable_sort(live, function(a, b) return a.seq < b.seq end)

  local bindings = {}
  for _, entry in ipairs(live) do
    bindings[#bindings + 1] = {
      ref = entry.ref, pos = entry.pos, order = entry.order,
    }
  end
  local pin
  if nil ~= point then
    pin = T.getv(T.getv(self.points, point) or T.map {}, 'pin')
  end
  return Ord.resolve_order(bindings, pin)
end

-- --- points -----------------------------------------------------

-- Live bindings on a point, in resolved order. Recomputed on any change to
-- the live set (section 7) rather than cached at startup - the bug a host
-- discovers only when something deactivates in production.
function Host:bound(point)
  local out = {}
  for _, ref in ipairs(self:order(point)) do
    local entry = self.inst[ref]
    -- The band is the INSTANCE's ordering block (section 7), stamped by
    -- the host. A plugin passing its own would be ranking itself above the
    -- order its document declared.
    local block = T.ismap(entry.order) and entry.order or T.map {}
    local band = T.getv(block, 'band')
    band = 'integer' == math.type(band) and band or 0
    for _, b in ipairs(entry.bindings) do
      if b.point == point then
        out[#out + 1] = { ref = b.ref, point = b.point, fn = b.fn, band = band }
      end
    end
  end
  return out
end

function Host:pointspec(point, want)
  if not T.has(self.points, point) then
    T.fail('plugin_point_unknown', 'no such point: ' .. tostring(point),
           T.map { point = point })
  end
  local spec = self.points[point]
  local kind = T.getv(spec, 'kind')
  if 'hook' == want then
    -- A point with no declared kind is a hook, which is what makes `{}`
    -- the minimal point declaration.
    if nil ~= kind and 'hook' ~= kind then
      T.fail('plugin_point_kind', 'point is not a hook: ' .. point,
             T.map { point = point, kind = kind })
    end
    return spec
  end
  if kind ~= want then
    T.fail('plugin_point_kind', 'point is not a ' .. want .. ': ' .. point,
           T.map { point = point, kind = kind })
  end
  return spec
end

function Host:emit(point, arg)
  local spec = self:pointspec(point, 'hook')
  return Pt.point_emit(self:bound(point), T.getv(spec, 'mode') or 'emit', arg)
end

function Host:call(point, ...)
  local spec = self:pointspec(point, 'chain')
  local base = T.getv(spec, 'base')
  if 'function' ~= type(base) then
    base = function(v) return v end
  end
  return Pt.compose(self:bound(point), base)(...)
end

function Host:provider(point, ...)
  local spec = self:pointspec(point, 'provider')
  local pick = Pt.point_provider(self:bound(point), spec)
  if nil == pick.winner then return T.getv(spec, 'default') end
  return pick.winner.fn(nil, ...)
end

-- The losers are VISIBLE rather than silently ignored (section 6.3).
function Host:shadowed(point)
  if not T.has(self.points, point) then return T.list {} end
  return Pt.point_provider(self:bound(point), self.points[point]).shadowed
end

function Host:exports(spec)
  local all = {}
  for _, ref in ipairs(self:refs()) do
    local entry = self.inst[ref]
    -- Exports of a `loaded` (not live) instance are VISIBLE (11).
    if 'declared' ~= entry.status and 'failed' ~= entry.status then
      local keys = {}
      for k in pairs(entry.exportkeys) do keys[#keys + 1] = k end
      table.sort(keys)
      for _, k in ipairs(keys) do
        all[#all + 1] = { ref = ref, key = k, value = entry.exports[k] }
      end
    end
  end
  return Ex.resolve_export(spec, all)
end

-- The live providers of a capability, best-first (section 11.1).
function Host:capability(name)
  local cands = {}
  for _, ref in ipairs(self:refs()) do
    local entry = self.inst[ref]
    if 'live' == entry.status then
      for _, prov in ipairs(entry.provides) do
        if T.getv(prov, 'name') == name then
          cands[#cands + 1] = T.map {
            ref = ref, pos = entry.pos, provides = prov,
          }
        end
      end
    end
  end
  local ranked = Cap.resolve_capability(T.map { name = name }, T.list(cands))
  local out = {}
  for i = 1, #ranked do out[#out + 1] = T.getv(ranked[i], 'ref') end
  return T.list(out)
end

-- --- documents --------------------------------------------------

function Host:shapeof(ref)
  local definition = self.catalog:get(R.refname(ref))
  if nil == definition then return nil end
  return definition.shape
end

-- Section 9.6: "load what is missing, UNLOAD WHAT IS GONE, patch what
-- changed, and move activation state to match", with the stated ordering -
-- "deactivations and unloads first (reverse load order), then loads, then
-- activations in load order".
--
-- FOUR PHASES, NOT ONE INTERLEAVED LOOP. An earlier draft walked the
-- document once, which never looked at instances the new document had
-- DROPPED - so an integration removed from a config reload stayed live
-- with its bindings and resources.
function Host:apply(doc, profile)
  self:guard()
  if nil == profile then profile = T.getv(self.opts, 'profile') end

  local norm = Cfg.normalize_config(T.map {
    doc = doc,
    profile = profile,
    keys = T.getv(self.opts, 'keys'),
    reserved = self.reserved,
  })

  local want = {}
  for i = 1, T.len(norm.order) do want[#want + 1] = norm.order[i] end

  local defaults = T.getv(self.opts, 'defaults') or T.map {}
  local optionsof = {}
  for _, ref in ipairs(want) do
    optionsof[ref] = Cfg.resolve_options(T.map {
      ref = ref,
      doc = doc,
      profile = profile,
      shape = self:shapeof(ref),
      hostdefaults = T.getv(defaults, R.refname(ref)),
    })
  end

  -- Should this ref be LIVE after the apply? False for a ref the document
  -- declares lazy or inactive AND for one it does not name at all - which
  -- is what makes "unload what is gone" and "unload what was toggled off"
  -- one rule rather than two.
  local function wantlive(ref)
    local ent = T.getv(norm.instance, ref)
    return nil ~= ent and T.truthy(T.getv(ent, 'active'))
        and 'eager' == T.getv(ent, 'start')
  end

  -- --- phase 1: deactivations and unloads, REVERSE load order ----
  local drop = {}
  for _, ref in ipairs(self:refs()) do
    if 'declared' ~= self.inst[ref].status and not wantlive(ref) then
      drop[#drop + 1] = ref
    end
  end
  -- Highest `pos` first, ref-descending for a tie, so a consumer declared
  -- after its provider goes down first.
  local inst = self.inst
  table.sort(drop, function(a, b)
    if inst[a].pos ~= inst[b].pos then return inst[a].pos > inst[b].pos end
    return a > b
  end)
  for _, ref in ipairs(drop) do self:unload(ref) end

  -- --- phase 2: declare and patch EVERYTHING, in load order ------
  for _, ref in ipairs(want) do
    local ent = T.getv(norm.instance, ref)
    -- NO OPTIONS HERE, and the omission is the fix rather than an
    -- oversight. `declare` ADOPTS the options table it is handed as the
    -- instance's own, so passing the resolved table made target and
    -- source THE SAME TABLE in the refill below - which cleared its own
    -- source and left a first-time instance with no options at all.
    -- `declare` makes its own empty table and the refill fills it, so
    -- both paths are now one path.
    self:declare(ref, T.map {
      order = T.getv(ent, 'order'),
      pos = T.getv(ent, 'pos'),
    })
    -- The bar is REASSERTED ON EVERY APPLY, in both directions - a
    -- document that turns the instance back on clears it, which is the
    -- whole point of a config switch.
    self.inst[ref].barred = not T.truthy(T.getv(ent, 'active'))
    -- REFILL rather than REBIND. A definition's callbacks close over the
    -- options table they were handed at `define`.
    local target = self.inst[ref].options
    for k in pairs(target) do target[k] = nil end
    for k, v in pairs(optionsof[ref]) do target[k] = v end
    self.inst[ref].order = T.getv(ent, 'order')
    self.inst[ref].pos = T.getv(ent, 'pos')
  end

  -- --- phase 3: loads, in load order -----------------------------
  -- ONLY THE EAGER, ACTIVE ONES: "a document of twenty lazy instances is
  -- twenty map entries and no executed code" (9.6).
  for _, ref in ipairs(want) do
    if wantlive(ref) then self:load(ref) end
  end

  -- --- phase 4: activations, in load order -----------------------
  for _, ref in ipairs(want) do
    if wantlive(ref) then self:activate(ref) end
  end
end

function Host:options(ref, patch)
  self:guard()
  local entry = self:need(ref)
  local previous = T.map {}
  for k, v in pairs(entry.options) do previous[k] = v end

  local merged = T.map {}
  for k, v in pairs(previous) do merged[k] = v end
  for _, k in ipairs(T.keys(patch)) do merged[k] = patch[k] end

  local resolved = Cfg.resolve_options(T.map {
    ref = entry.ref,
    shape = self:shapeof(entry.ref),
    doc = T.map {},
    patch = merged,
  })
  local target = entry.options
  for k in pairs(target) do target[k] = nil end
  for k, v in pairs(resolved) do target[k] = v end

  if 'live' ~= entry.status then return end

  local reconfigure = entry.def.reconfigure
  if 'function' == type(reconfigure) then
    self.transition = true
    local ok, err = pcall(reconfigure, Inst.new(self, entry), entry.options,
                          previous)
    self.transition = false
    if not ok then error(err, 0) end
  else
    -- Always correct and sometimes expensive; `reconfigure` exists to make
    -- the common case cheap (section 9.4).
    self:deactivate(entry.ref)
    self:activate(entry.ref)
  end
end

function Host:close()
  -- A bulk teardown removing the holders too, so `hold` is suspended for
  -- exactly those holders (section 11.3) - while the consumers-first
  -- cascade still runs, which is the half that matters.
  self.coordinated = true
  local refs = self:refs()
  local ok, err = pcall(function()
    for i = #refs, 1, -1 do
      if nil ~= self.inst[refs[i]] then self:unload(refs[i]) end
    end
  end)
  self.coordinated = false
  if not ok then error(err, 0) end
end

-- The same record section 6.6 gives a plugin about itself, reachable from
-- outside for the corpus.
function Host:positionof(ref, point)
  local entry = self.inst[R.canon(ref)]
  if nil == entry then
    T.fail('plugin_not_loaded', 'no such instance: ' .. tostring(ref),
           T.map { ref = ref })
  end
  local ranked = self:order(point)
  local index = -1
  for i = 1, #ranked do
    if ranked[i] == entry.ref then index = i - 1 break end
  end
  return T.map {
    index = index,
    count = #ranked,
    -- Section 6.2 composes b1(b2(b3(base))) with the FIRST binding
    -- OUTERMOST, so these are not index 0 and index count-1 the other way
    -- round.
    outermost = 0 == index,
    innermost = index == #ranked - 1,
  }
end

return M
