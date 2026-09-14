-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lua/src/sekreto.lua)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- sekreto: one interface for secrets, wherever they live.
--
-- A Sekreto is an ordered chain of providers. `get` asks each in turn and
-- returns the first hit, so an app can be configured from environment
-- variables in development and a vault in production without changing a
-- line of its own code.
--
-- This module is the whole core surface: the facade, the pure name
-- functions (re-exported from sekreto.name, which the providers need
-- too), the error type, and the four built-in provider kinds.
--
-- THE CORE REQUIRES NO PROVIDER THAT OPENS A SOCKET, SPAWNS A PROCESS OR
-- SIGNS A REQUEST. The four built-in kinds - env, memory, dotenv, file -
-- read at most a local file; every other kind is a voxgig/plugin
-- definition under sekreto/plugins/, and a chain may name one only if the
-- calling project handed it in through `plugins`:
--
--     local sekreto = require('sekreto')
--     local hashicorp = require('feature.secrets.sekreto.plugins.hashicorp').hashicorp
--
--     local secrets = sekreto.sekreto({
--       plugins = { hashicorp },
--       providers = {
--         { kind = 'env' },
--         { kind = 'hashicorp', addr = addr, token = token },
--       },
--     })
--
-- or, for every kind at once, `allplugins` from `sekreto.plugins`. See
-- docs/design/plugin-providers.md.
--
-- A port of typescript/src/Sekreto.ts, which is canonical.

local plugin = require('feature.secrets.plugin')

local err = require('feature.secrets.sekreto.err')
local name = require('feature.secrets.sekreto.name')
local addr = require('feature.secrets.sekreto.addr')
local providers = require('feature.secrets.sekreto.providers')

local M = {}

-- ---------------------------------------------------------- re-exports

M.SekretoError = err.SekretoError
M.issekretoerror = err.issekretoerror
M.errmessage = err.message

M.validname = name.validname
M.checkname = name.checkname
M.envkey = name.envkey
M.vaultref = name.vaultref
M.flatname = name.flatname
M.awsparam = name.awsparam
M.parsedotenv = name.parsedotenv
M.redact = name.redact
M.storename = name.storename

M.checkaddr = addr.checkaddr
M.safeaddr = addr.safeaddr

M.spec = providers.spec
M.authspec = providers.authspec

-- The plugin bridge, and the four kinds built on it. `providerplugin` is
-- how a calling project adds a fifth.
M.providerplugin = providers.providerplugin
M.BUILTINS = providers.BUILTINS
M.KINDS = providers.KINDS
M.PROVIDER_EXPORT = providers.PROVIDER_EXPORT
M.ERROR_CODE = providers.ERROR_CODE

-- ------------------------------------------------------------- the type

local Sekreto = {}
Sekreto.__index = Sekreto

--- The stores this Sekreto can be asked by name, without repeats.
--- Defined before the print hooks, which are the only reason it needs to
--- come first.
function Sekreto:stores()
  local out = {}
  local seen = {}

  for _, entry in ipairs(self.entries) do
    if nil == seen[entry.store] then
      seen[entry.store] = true
      out[#out + 1] = entry.store
    end
  end

  return out
end

-- Print hooks, and they are not optional. `cache` and `seen` are
-- ordinary fields, so anything that walks or prints a Sekreto - a
-- debugger, a logging helper, an error formatter - would otherwise emit
-- every secret ever resolved. Neither hook reaches a value.
Sekreto.__tostring = function(self)
  return 'Sekreto { stores: [ ' .. table.concat(self:stores(), ', ') .. ' ] }'
end
Sekreto.__name = 'Sekreto'

--- The JSON-shaped form: the store names, and nothing else.
function Sekreto:tojson()
  return { stores = self:stores() }
end

-- ------------------------------------------------------- the plugin seam

--- Is this a voxgig/plugin definition?
local function isdefinition(value)
  return 'table' == type(value) and 'string' == type(value.name)
    and 'function' == type(value.define)
end

--- The name a table is loaded under, when it is a module.
---
--- Lua gives a module no identity of its own, so the registry is asked.
--- It is only ever consulted on the error path below, where naming the
--- module is the whole point of the message.
local function modulename(value)
  for key, loaded in pairs(package.loaded) do
    if loaded == value then
      return key
    end
  end
  return nil
end

--- A plugin entry, checked to be a definition before the catalog sees it.
---
--- `require('feature.secrets.sekreto.plugins.hashicorp')` hands back the MODULE, and the
--- definition is one field further on - so the thing nearest to hand is
--- not a definition, and a module in the catalog would fail deep inside
--- voxgig/plugin with a message about a definition name. Refused here
--- instead, naming the module and what to pass out of it.
local function definition(entry)
  if isdefinition(entry) then
    return entry
  end

  local modname = ('table' == type(entry)) and modulename(entry) or nil

  if nil ~= modname then
    -- What the module holds that could have been meant: a definition, or
    -- a list of them.
    local holds = {}
    for key, value in pairs(entry) do
      if isdefinition(value) or
        ('table' == type(value) and isdefinition(value[1]))
      then
        holds[#holds + 1] = key
      end
    end
    table.sort(holds)

    if 0 < #holds then
      err.fail('sekreto: not a plugin definition: the module ' .. modname ..
        " - pass a definition it holds, such as require('" .. modname ..
        "')." .. holds[1])
    end

    err.fail('sekreto: not a plugin definition: the module ' .. modname)
  end

  err.fail('sekreto: not a plugin definition: ' .. tostring(entry))
end

--- The message for a kind the catalog does not hold.
---
--- A kind sekreto has never heard of is a typo; a kind that exists as a
--- plugin but was not passed in is the split working as designed and
--- telling you what to pass. Collapsing the two was the first thing that
--- made the split confusing to use.
local function unknownkind(kind, catalog)
  local message = 'sekreto: unknown provider kind: ' .. tostring(kind) ..
    ' (available: ' .. table.concat(catalog:names(), ', ') .. ')'

  for _, known in ipairs(providers.KINDS.plugin) do
    if known == kind then
      return message .. ' - ' .. tostring(kind) ..
        ' is a sekreto plugin, not built in: pass it in the plugins option'
    end
  end

  return message
end

--- A SekretoError that crossed the plugin boundary comes back out as
--- itself, byte for byte. Anything else is not sekreto's to rewrite.
local function unwrap(raised)
  if providers.ERROR_CODE == plugin.codeof(raised) then
    local cause = ('table' == type(raised.details)) and raised.details.cause or nil
    if 'string' == type(cause) then
      return err.SekretoError(cause)
    end
  end

  return raised
end

--- One chain entry, as a plugin instance.
---
--- The instance is `kind` for a store named after its kind and
--- `kind$store` otherwise - `hashicorp$prod` - so `host:list()` reads like
--- the chain. A store name that is already taken gets a numbered tag from
--- the host instead, because two providers MAY share a store name (a
--- directed read walks both) and an instance ref may not.
function Sekreto:declare(spec)
  local kind = ('table' == type(spec)) and spec.kind or nil

  if 'string' ~= type(kind) or not self.catalog:has(kind) then
    err.fail(unknownkind(kind, self.catalog))
  end

  local store = providers.nonempty(spec.name) and spec.name or kind

  if 'string' ~= type(store) or not plugin.check_tag(store) then
    err.fail('sekreto: invalid store name: ' .. tostring(store))
  end

  local ref = (store == kind) and kind or plugin.format_ref(kind, store)
  if nil ~= self.host:instance(ref) then
    ref = self.host:autotag(kind)
  end

  -- `load` runs the definition's `define`, which builds the provider from
  -- the spec; `activate` takes the instance live. Nothing is contacted by
  -- either: a provider opens nothing until its first lookup.
  local ok, raised = pcall(function()
    self.host:load(ref, plugin.types.map({ options = spec }))
    self.host:activate(ref)
  end)

  if not ok then
    error(unwrap(raised), 0)
  end

  return {
    store = store,
    provider = self.host:exports(ref .. '/' .. providers.PROVIDER_EXPORT),
  }
end

--- Make a Sekreto.
---
--- `options` carries `plugins` (the definitions this chain may build,
--- beyond the four built-ins), `providers` (the chain itself, as specs or
--- as live providers) and `cache`. Construction contacts nothing: the
--- first network call is the first lookup.
function M.Sekreto(options)
  local self = setmetatable({}, Sekreto)
  local opts = options or {}

  -- An options TABLE, not a list of specs. Before the plugin split this
  -- took `sekreto(specs, cache)` positionally, and that call would now
  -- find no `providers` key and build an EMPTY CHAIN IN SILENCE - every
  -- `get` raising `unknown secret` with nothing to say why. A list is
  -- refused outright instead.
  if nil ~= opts[1] then
    err.fail('sekreto: sekreto() takes an options table' ..
      ' { plugins = ..., providers = ..., cache = ... }, not a list of specs')
  end

  -- Built-ins first, then the plugins, into one catalog: a plugin that
  -- names a built-in kind replaces it, which is how a host substitutes an
  -- implementation and never an accident, because the four names are
  -- documented.
  --
  -- `catalog` is the definitions this Sekreto can build; `host` is the
  -- voxgig/plugin host every spec'd provider is an instance of. Read them
  -- for introspection - `host:list()` names each store's ref and status -
  -- and nothing on either advances the chain.
  local defs = {}
  for _, builtin in ipairs(providers.BUILTINS) do
    defs[#defs + 1] = builtin
  end
  for _, given in ipairs(opts.plugins or {}) do
    defs[#defs + 1] = definition(given)
  end

  self.catalog = plugin.make_catalog(defs)
  self.host = plugin.make_host(plugin.types.map({ catalog = self.catalog }))

  -- {store, provider} pairs, in chain order. A provider handed in live is
  -- backed by no instance; a spec'd one is an instance of its kind on the
  -- host.
  self.entries = {}

  for index, entry in ipairs(opts.providers or {}) do
    if 'function' == type(entry.lookup) then
      self.entries[index] = { store = name.storename(entry), provider = entry }
    else
      self.entries[index] = self:declare(entry)
    end
  end

  -- A list, not a map: the store a value came from stays attached, and
  -- redaction order does not vary between runs.
  self.cache = {}

  -- Every value ever resolved, for redact(). Kept independently of the
  -- read cache so that redaction still works when caching is off -
  -- otherwise an uncached Sekreto would silently disable redact() and
  -- leak secrets to logs. Append-only for the object's life: neither
  -- refresh() nor close() clears it.
  self.seen = {}

  -- A strict identity test, as canonical: only an exact `false` turns
  -- caching off, so nil leaves it on.
  self.docache = (false ~= opts.cache)

  return self
end

--- The one resolution path both readers share.
function Sekreto:resolve(store, secret, useentries)
  -- The name is validated FIRST: before the cache, before the first
  -- provider.
  name.checkname(secret)

  if self.docache then
    for _, hit in ipairs(self.cache) do
      if store == hit.store and secret == hit.name then
        return hit.value
      end
    end
  end

  for _, entry in ipairs(useentries) do
    local found = entry.provider.lookup(secret)

    -- The empty string is a HIT. Only nil is a miss, and a provider that
    -- raises is not caught here: the error propagates out of get/try.
    if nil ~= found then
      if self.docache then
        self.cache[#self.cache + 1] = { store = store, name = secret, value = found }
      end
      self.seen[#self.seen + 1] = found
      return found
    end
  end

  -- Misses are never cached.
  return nil
end

--- The secret, or nil if no provider has it.
---
--- Named `tryget` because `try` is not usable as a Lua field name without
--- quoting at every call site; `sekreto['try']` is kept as an alias for
--- callers translating from canonical.
function Sekreto:tryget(secret)
  return self:resolve('', secret, self.entries)
end

Sekreto.try = Sekreto.tryget

--- The secret, or a SekretoError if no provider has it.
function Sekreto:get(secret)
  local found = self:tryget(secret)

  if nil == found then
    err.fail('sekreto: unknown secret: ' .. tostring(secret))
  end

  return found
end

--- The secret from one named store, or nil if that store does not have
--- it.
---
--- Naming a store that is not in the chain is an error, not a miss:
--- `tryget` already means "this store may not have it", so it cannot also
--- mean "this store may not exist" without hiding a typo. It is raised
--- BEFORE the name is validated.
function Sekreto:tryfrom(store, secret)
  local matching = {}

  for _, entry in ipairs(self.entries) do
    if store == entry.store then
      matching[#matching + 1] = entry
    end
  end

  if 0 == #matching then
    err.fail('sekreto: unknown store: ' .. tostring(store))
  end

  return self:resolve(store, secret, matching)
end

--- The secret from one named store, or a SekretoError.
function Sekreto:getfrom(store, secret)
  local found = self:tryfrom(store, secret)

  if nil == found then
    err.fail('sekreto: unknown secret: ' .. tostring(store) .. ':' .. tostring(secret))
  end

  return found
end

--- Does any provider have this secret?
function Sekreto:has(secret)
  return nil ~= self:tryget(secret)
end

--- Does this named store have this secret?
function Sekreto:hasin(store, secret)
  return nil ~= self:tryfrom(store, secret)
end

--- Every named secret at once. Missing ones are an error.
function Sekreto:all(secrets)
  local out = {}
  local order = {}

  for _, secret in ipairs(secrets) do
    out[secret] = self:get(secret)
    order[#order + 1] = secret
  end

  return out, order
end

--- A description of each provider, in resolution order, repeats kept.
function Sekreto:sources()
  local out = {}

  for index, entry in ipairs(self.entries) do
    out[index] = entry.provider.describe()
  end

  return out
end

--- Replace every value this Sekreto has resolved with `[redacted]`.
--- Works whether or not caching is enabled.
function Sekreto:redact(text)
  return name.redact(text, self.seen)
end

--- Drop cached values, so the next `get` asks the providers again. The
--- redaction history is NOT cleared.
function Sekreto:refresh()
  self.cache = {}
end

--- Tear the chain down: every plugin instance is deactivated and
--- unloaded, in reverse, releasing whatever a provider acquired at
--- activation. Afterwards `stores()` and `sources()` are empty, `tryget`
--- misses and `get` raises - and `redact` still knows every value ever
--- resolved.
function Sekreto:close()
  self.host:close()
  self.entries = {}
  self.cache = {}
end

M.SekretoClass = Sekreto

-- ---------------------------------------------------------- the factory

--- Make a Sekreto from options - the same shape the shared spec and an
--- app's config file use.
---
--- A `providers` element that already has a callable `lookup` is taken as
--- a live provider (duck-typed, never by class identity) and keeps its
--- own describe()-derived store name.
function M.sekreto(options)
  return M.Sekreto(options)
end

return M
