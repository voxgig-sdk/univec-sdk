-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lua/src/plugin/graph.lua)
-- Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- Whole-graph resolution (section 11.4) - a phase, not a discovery.
--
-- "Activate, and wait in `pending` if you must" is correct and, on its
-- own, produces a terrible experience: apply twenty instances against a
-- registry missing one thing and you get NINETEEN pending rows and no
-- statement of what is actually wrong.
--
-- `resolve_graph` is a PURE FUNCTION of the registry and the intended
-- activation set. No callbacks run, no state changes, nothing is touched.
-- It answers for the whole graph at once which instances can be live, and
-- for each blocked one THE SPECIFIC REQUIREMENT that is unmet, and why.
--
-- The failure mode being designed against is a famous one: OSGi's resolver
-- is correct and its diagnostics are legendarily unusable. A resolver that
-- says "blocked" without saying WHY has moved the problem rather than
-- solved it, so `why` is part of the contract and the corpus pins its
-- shape.

local T = require 'feature.secrets.plugin.types'
local Cap = require 'feature.secrets.plugin.capability'
local V = require 'feature.secrets.plugin.version'
local R = require 'feature.secrets.plugin.ref'

local M = {}

local function candidates(byref, refs, name)
  local out = {}
  -- A NODE SATISFIES ITS OWN REF (section 11.1), and the graph learned it
  -- here. Considering only declared capabilities made `resolve` answer
  -- `absent` about a provider sitting right there and live - section
  -- 11.4's job is explaining the graph the runtime reconciles.
  local asref = R.canon(name)
  -- Sorted refs, so the walk is deterministic in a language whose tables
  -- have no order at all.
  for _, ref in ipairs(refs) do
    local node = byref[ref]
    -- The ref match WINS OUTRIGHT for that node, as at runtime: one
    -- candidate, not two, for a node both named `b` and providing `b`.
    if ref == asref then
      out[#out + 1] = T.map {
        ref = T.getv(node, 'ref'),
        pos = T.getv(node, 'pos') or 0,
        provides = T.map { name = name },
      }
      goto continue
    end
    local provides = T.getv(node, 'provides') or T.list {}
    for i = 1, T.len(provides) do
      local prov = provides[i]
      if T.same(T.getv(prov, 'name'), name) then
        out[#out + 1] = T.map {
          ref = T.getv(node, 'ref'),
          pos = T.getv(node, 'pos') or 0,
          provides = prov,
        }
      end
    end
    ::continue::
  end
  return T.list(out)
end

local function unmet(node, name, why)
  return T.map { ref = T.getv(node, 'ref'), unmet = name, why = why }
end

local function firstunmet(node, byref, refs, resolved)
  local requires = T.getv(node, 'requires') or T.list {}
  for i = 1, T.len(requires) do
    local req = requires[i]
    if not T.truthy(T.getv(req, 'optional')) then
      local name = T.getv(req, 'name')
      local all = candidates(byref, refs, name)
      if 0 == #all then
        return unmet(node, name, T.map { kind = 'absent' })
      end

      local ok = Cap.resolve_capability(req, all)
      if 0 < #ok then
        -- A provider exists and matches - but if none of them is itself
        -- resolved, this node is blocked BEHIND it, and the chain is the
        -- useful answer rather than "unmet".
        local any = false
        for j = 1, #ok do
          if resolved[T.getv(ok[j], 'ref')] then any = true break end
        end
        if not any then
          local chain = {}
          for j = 1, #ok do chain[#chain + 1] = T.getv(ok[j], 'ref') end
          table.sort(chain)
          return unmet(node, name,
                       T.map { kind = 'blocked', chain = T.list(chain) })
        end
      else
        -- Providers exist and none matched. Say which test failed.
        local range = T.getv(req, 'range')
        if nil ~= range then
          local versions = {}
          for j = 1, #all do
            local have = T.getv(T.getv(all[j], 'provides'), 'version')
            if nil == have or not V.satisfiesq(have, range) then
              versions[#versions + 1] = have or '(none)'
            end
          end
          if 0 < #versions then
            table.sort(versions)
            return unmet(node, name, T.map {
              kind = 'version', range = range, found = T.list(versions),
            })
          end
        end

        local want = T.getv(req, 'match')
        if nil ~= want then
          for j = 1, #all do
            local attrs = T.getv(T.getv(all[j], 'provides'), 'attrs') or T.map {}
            for _, k in ipairs(T.keys(want)) do
              if not (T.has(attrs, k) and Cap.matchvalue(want[k], attrs[k])) then
                -- `T.has(attrs, k) and attrs[k] or T.NULL` would report a
                -- present FALSE as a null: lua's `and`/`or` is not a
                -- ternary when the middle term can be false, and
                -- `graph/blocked#match` is exactly that case.
                local found = T.NULL
                if T.has(attrs, k) then found = attrs[k] end
                return unmet(node, name, T.map {
                  kind = 'match', failing = k, want = want[k], found = found,
                })
              end
            end
          end
        end

        return unmet(node, name, T.map { kind = 'absent' })
      end
    end
  end
  return nil
end

function M.resolve_graph(nodes)
  local byref = {}
  local refs = {}
  for i = 1, T.len(nodes) do
    local ref = T.getv(nodes[i], 'ref')
    byref[ref] = nodes[i]
    refs[#refs + 1] = ref
  end
  table.sort(refs)

  local resolved = {}
  local blocked = {}

  -- Fixed point: a node resolves when every mandatory requirement is met
  -- by an ALREADY-RESOLVED provider. Iterating to a fixed point is what
  -- makes a provider that is itself blocked propagate, rather than each
  -- node being judged against the raw registry.
  local moved = true
  while moved do
    moved = false
    for i = 1, T.len(nodes) do
      local n = nodes[i]
      local ref = T.getv(n, 'ref')
      if not resolved[ref] and nil == firstunmet(n, byref, refs, resolved) then
        resolved[ref] = true
        moved = true
      end
    end
  end

  for i = 1, T.len(nodes) do
    local n = nodes[i]
    local ref = T.getv(n, 'ref')
    if not resolved[ref] then
      local why = firstunmet(n, byref, refs, resolved)
      if nil ~= why then blocked[ref] = why end
    end
  end

  local resolvedout = {}
  for _, ref in ipairs(refs) do
    if resolved[ref] then resolvedout[#resolvedout + 1] = ref end
  end
  local blockedout = {}
  for _, ref in ipairs(refs) do
    if nil ~= blocked[ref] then blockedout[#blockedout + 1] = blocked[ref] end
  end

  return T.map { resolved = T.list(resolvedout), blocked = T.list(blockedout) }
end

return M
