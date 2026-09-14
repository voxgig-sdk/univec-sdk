-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lua/src/plugin/depend.lua)
-- Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- Dependency cardinality, policy, and the restart graph (section 11.3).
--
-- TWO AXES, BOTH DECLARED BY THE DEFINITION THAT HAS THE REQUIREMENT,
-- because only it knows what it can cope with:
--
--                | static (default)          | dynamic
--   -------------|---------------------------|--------------------------
--   mandatory    | unmet -> pending;         | unmet -> pending;
--   (default)    | lost  -> pending,         | lost  -> STAYS LIVE,
--                |          recursively      |          notified
--   -------------|---------------------------|--------------------------
--   optional:true| never gates activation;   | never gates activation;
--                | a change deactivates and  | a change is a
--                | reactivates               | notification, nothing else
--
-- `dynamic` means the plugin has said, IN WRITING, that it can survive its
-- provider being swapped underneath it. It is not the default because most
-- plugins cannot, and the cost of wrongly assuming they can is a live
-- instance holding a dead reference.
--
-- The rebinding-preference axis is deliberately omitted. OSGi has
-- reluctant vs greedy and it is a knob every author must understand to
-- read anyone else's component; we take always-reluctant. Three axes were
-- more than the model can carry across twenty ports.

local T = require 'feature.secrets.plugin.types'
local R = require 'feature.secrets.plugin.ref'

local M = {}

-- A bare string is shorthand for `{name}`.
function M.normrequire(raw)
  if 'string' == type(raw) then
    return T.map { name = raw }
  end
  if not T.ismap(raw) then return T.map {} end
  local out = T.map {}
  for k, v in pairs(raw) do out[k] = v end
  return out
end

-- The requirements a definition declared, normalized.
--
-- BOTH AXES ARE READ AT TWO LEVELS, AND THE PER-REQUIREMENT ONE WINS.
--
-- The instance-level `policy` and `optional` list are how a DOCUMENT
-- states the axis without editing the definition, and they apply to every
-- requirement. The per-requirement form is the one section 11.1's object
-- syntax exists for, and it is strictly more expressive: an instance that
-- is `static` on its store and `dynamic` on its metrics cannot be written
-- at all at the instance level.
--
-- `optional` unions rather than overriding - both spellings are statements
-- that this requirement need not gate activation, and there is no reading
-- under which one of them means "actually, mandatory".
function M.requirements(options)
  local raw = T.getv(options, 'requires') or T.list {}
  local marked = T.getv(options, 'optional')
  local fallback = T.getv(options, 'policy')

  local out = {}
  for i = 1, T.len(raw) do
    local req = M.normrequire(raw[i])
    local ismarked = false
    if T.islist(marked) then
      for j = 1, #marked do
        if T.same(marked[j], T.getv(req, 'name')) then ismarked = true break end
      end
    end
    if T.truthy(T.getv(req, 'optional')) or ismarked then
      req.optional = true
    end
    if nil == T.getv(req, 'policy') and nil ~= fallback then
      req.policy = fallback
    end
    out[#out + 1] = req
  end
  return out
end

-- Does losing this requirement's SELECTED provider restart the consumer?
-- The mandatory ones under `static`, and the `static` optional ones - both
-- make a capability change deactivate and reactivate. `dynamic` never
-- restarts.
function M.restartsonloss(req)
  return 'dynamic' ~= (T.getv(req, 'policy') or 'static')
end

-- Does an unmet requirement keep the consumer out of `live`?
--
-- Cardinality alone decides this, NOT policy. `dynamic` is a statement
-- about surviving a SWAP, not about starting without the thing at all - a
-- mandatory-dynamic consumer still waits in `pending` for its first
-- provider.
function M.gatesactivation(req)
  return true ~= T.getv(req, 'optional')
end

-- Edges that can cause a restart, which is exactly the set a cycle must be
-- detected over (section 11.3).
--
-- ONLY `dynamic` OPTIONAL EDGES ARE EXCLUDED, and they are the ones the
-- exclusion was for: two plugins that optionally and dynamically consume
-- each other's capabilities both activate happily, neither gates on the
-- other, and each is merely notified when the other appears. Nothing
-- restarts, so nothing oscillates.
--
-- An earlier draft of section 11.3 excluded EVERY optional edge and
-- thereby admitted the non-terminating case it was trying to permit.
function M.restartcausing(req)
  return M.gatesactivation(req) or M.restartsonloss(req)
end

-- A cycle through restart-causing requirements is
-- `plugin_dependency_cycle`, detected AT LOAD - before anything runs,
-- because the failure it describes is a non-terminating reconcile and the
-- only safe time to report that is before it starts.
--
-- The graph is over capabilities, not refs: an edge runs from a consumer
-- to EVERY node that provides what it needs, because any of them could be
-- the one selected and a cycle through any is a cycle. A node also
-- satisfies its own name as a ref (section 11.1), which is why the ref is
-- a provider of itself here.
--
-- `nodes` is a plain lua array of {ref=, provides=, requires=} records.
function M.dependencycycle(nodes)
  -- TWO INDEXES, NOT ONE MERGED MAP. Capability names and refs are
  -- matched differently - a capability by its exact name, a ref through
  -- the canonical spelling (section 4 rule 5) - and one map keyed by both
  -- can only do one of them. Keyed by both and looked up raw, as this
  -- was, a cycle spelled `a$`/`b$` found no providers and EVADED the
  -- load-time check that exists to catch a non-terminating reconcile.
  local bycap = {}
  local isref = {}
  for _, n in ipairs(nodes) do
    isref[n.ref] = true
    for _, cap in ipairs(n.provides) do
      if nil == bycap[cap] then bycap[cap] = {} end
      table.insert(bycap[cap], n.ref)
    end
  end

  local edges = {}
  local starts = {}
  for _, n in ipairs(nodes) do
    local out = {}
    local seen = {}
    for _, req in ipairs(n.requires) do
      if M.restartcausing(req) then
        local reqname = T.getv(req, 'name')
        local from = {}
        for _, p in ipairs(bycap[reqname] or {}) do from[#from + 1] = p end
        -- A node satisfies its own name AS A REF (section 11.1),
        -- canonically - exactly what `providersof` does at runtime.
        -- `canon` hands back a name no ref could have unchanged, and no
        -- instance ref can equal one, so it is the tolerant test.
        local asref = R.canon(reqname)
        if isref[asref] then
          local dup = false
          for _, p in ipairs(from) do if p == asref then dup = true end end
          if not dup then from[#from + 1] = asref end
        end
        for _, p in ipairs(from) do
          if p ~= n.ref and not seen[p] then
            seen[p] = true
            out[#out + 1] = p
          end
        end
      end
    end
    table.sort(out)
    edges[n.ref] = out
    starts[#starts + 1] = n.ref
  end
  table.sort(starts)

  -- Iterative DFS with an explicit stack: twenty ports, and several of
  -- them have no recursion budget worth relying on.
  local WHITE, GREY, BLACK = 0, 1, 2
  local colour = {}
  for _, n in ipairs(nodes) do colour[n.ref] = WHITE end

  for _, start in ipairs(starts) do
    if WHITE == colour[start] then
      local path = { start }
      local stack = { { start, 1 } }
      colour[start] = GREY

      while 0 < #stack do
        local top = stack[#stack]
        local outs = edges[top[1]]
        if #outs < top[2] then
          colour[top[1]] = BLACK
          table.remove(stack)
          table.remove(path)
        else
          local nxt = outs[top[2]]
          top[2] = top[2] + 1
          if GREY == colour[nxt] then
            -- Report the cycle itself, not the walk that found it.
            local at = 1
            while at <= #path and path[at] ~= nxt do at = at + 1 end
            local cycle = {}
            for i = at, #path do cycle[#cycle + 1] = path[i] end
            cycle[#cycle + 1] = nxt
            return cycle
          elseif BLACK ~= colour[nxt] then
            colour[nxt] = GREY
            path[#path + 1] = nxt
            stack[#stack + 1] = { nxt, 1 }
          end
        end
      end
    end
  end
  return nil
end

-- Raise on a cycle, naming it. Separate from the detector so the detector
-- stays pure and corpus-testable.
function M.checkcycle(nodes)
  local cycle = M.dependencycycle(nodes)
  if nil == cycle then return end
  T.fail('plugin_dependency_cycle',
         'requirements cycle: ' .. table.concat(cycle, ' -> '),
         T.map { cycle = T.list(cycle) })
end

return M
