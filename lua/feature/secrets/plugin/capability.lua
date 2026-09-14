-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lua/src/plugin/capability.lua)
-- Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- Capabilities (section 11.1).
--
-- A DEPENDENCY IS ON A CAPABILITY, NOT ON A REF - because it is a
-- dependency on something that can do the job, and which instance is doing
-- it is exactly the configuration detail a plugin must not care about.
--
-- But A BINDING IS TO AN INSTANCE, not to a capability, which is what
-- decides behaviour when the bound provider leaves while another match
-- remains.

local T = require 'feature.secrets.plugin.types'
local V = require 'feature.secrets.plugin.version'

local M = {}

-- Rank the matching live providers and return them best-first: highest
-- `version`, then LOWEST `priority` (default 0), then declaration position
-- `pos` ascending.
--
-- `priority` is a field on the capability rather than section 7's `order`
-- band, because bands live on POINT BINDINGS: a provider may have several
-- bindings with different bands, or none at all, so a rank reaching for
-- one would be undefined in the common case.
--
-- Without a total rank, "any provider satisfies" is true of the GRAPH and
-- useless to the PLUGIN - two ports could bind different `store`
-- instances, both resolve green, and behave differently, which is
-- precisely the divergence a shared corpus exists to catch.
function M.resolve_capability(req, candidates)
  local hits = {}
  for i = 1, T.len(candidates) do
    local c = candidates[i]
    if M.matches(req, T.getv(c, 'provides') or T.map {}) then
      hits[#hits + 1] = c
    end
  end
  -- STABLE: table.sort is not, and the rank falls through to `pos`.
  return T.list(T.stable_sort(hits, M.ranks))
end

-- Best-first: true when `a` outranks `b`.
function M.ranks(a, b)
  local pa = T.getv(a, 'provides') or T.map {}
  local pb = T.getv(b, 'provides') or T.map {}
  local va = T.getv(pa, 'version')
  local vb = T.getv(pb, 'version')

  -- An ABSENT version sorts LAST, whatever the other is - "no version"
  -- loses to every version rather than being read as 0.0.0.
  if (nil == va) ~= (nil == vb) then
    return nil ~= va
  end
  if nil ~= va then
    local la, lb = V.version_parts(va), V.version_parts(vb)
    for i = 1, math.max(#la, #lb) do
      local x, y = la[i] or 0, lb[i] or 0
      if x ~= y then return x > y end
    end
  end

  local qa = T.getv(pa, 'priority') or 0
  local qb = T.getv(pb, 'priority') or 0
  if qa ~= qb then return qa < qb end

  return (T.getv(a, 'pos') or 0) < (T.getv(b, 'pos') or 0)
end

function M.matches(req, prov)
  if not T.same(T.getv(req, 'name'), T.getv(prov, 'name')) then
    return false
  end

  local range = T.getv(req, 'range')
  if nil ~= range then
    local version = T.getv(prov, 'version')
    if nil == version then return false end
    if not V.satisfiesq(version, range) then return false end
  end

  -- `match` is checked against the provider's `attrs`, key by key. A key
  -- the provider does not carry is a miss, not a pass: a requirement
  -- asking for `transactional: true` must not be satisfied by a provider
  -- that never said.
  local want = T.getv(req, 'match')
  if nil ~= want then
    local attrs = T.getv(prov, 'attrs') or T.map {}
    for _, k in ipairs(T.keys(want)) do
      if not T.has(attrs, k) then return false end
      if not M.matchvalue(want[k], attrs[k]) then return false end
    end
  end

  return true
end

-- PARTIAL MATCH, RECURSING INTO MAPS (section 11.1).
--
-- Section 11.1 defines `match` as "a partial match against `attrs`, with
-- exactly the semantics voxgig/struct and the omni corpus already define
-- for `match` - every leaf in the requirement must be present and equal in
-- the capability, keys not mentioned are not checked."
--
-- Equality is by JSON TYPE as well as value: `transactional: 1` does not
-- satisfy `transactional: true`. LUA NEEDS NO GUARD FOR THAT - `true == 1`
-- and `1 == '1'` are both false, with no coercion in `==` - so the
-- explicit check php and perl each carry would be dead code here. What lua
-- DOES need is the tagged tables, without which `{}` and `[]` would take
-- the same branch.
--
-- A LIST IS COMPARED LEAF-WISE AT THE SAME LENGTH, not as a subset.
function M.matchvalue(want, got)
  if T.ismap(want) then
    if not T.ismap(got) then return false end
    for _, k in ipairs(T.keys(want)) do
      if not T.has(got, k) then return false end
      if not M.matchvalue(want[k], got[k]) then return false end
    end
    return true
  end

  if T.islist(want) then
    if not T.islist(got) or #want ~= #got then return false end
    for i = 1, #want do
      if not M.matchvalue(want[i], got[i]) then return false end
    end
    return true
  end

  return T.same(want, got)
end

return M
