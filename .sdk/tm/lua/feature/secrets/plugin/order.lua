-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lua/src/plugin/order.lua)
-- Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- Ordering (section 7) - one rule, one place.
--
-- sdkgen grew two special cases in `makeOptions` (`test`, then `station`)
-- and the third was not far off. This sort is the whole replacement, and
-- the tiers are in this order for a reason:
--
--   1 constraints   before/after edges, by ref or by name
--   2 bands         integer, lower first, default 0
--   3 declaration   ties break by `pos`
--
-- CONSTRAINTS BEAT BANDS precisely so the correct tool wins when both are
-- present. A band expresses a genuine cross-cutting layer; a constraint
-- expresses a relationship between two specific things; and a band chosen
-- by trial and error to fix an ordering bug is a bug wearing a number.

local T = require 'feature.secrets.plugin.types'
local R = require 'feature.secrets.plugin.ref'

local M = {}

-- An integer, and only an integer: `true` and `'2'` are not bands, and lua
-- would coerce the string in a comparison.
function M.order_band(binding)
  local block = binding.order
  if not T.ismap(block) then return 0 end
  local value = T.getv(block, 'band')
  if 'integer' == math.type(value) then return value end
  return 0
end

-- Was a constraint stated? An absent value and an EMPTY LIST are both
-- no-constraint - and an empty list is TRUTHY in lua as in ruby, which is
-- exactly how this class of bug survives a reading.
function M.order_declared(spec)
  if nil == spec or T.NULL == spec then return false end
  if T.islist(spec) then
    for i = 1, #spec do
      if '' ~= spec[i] then return true end
    end
    return false
  end
  return '' ~= spec
end

-- One spelling or a LIST of them. A list fans out to the UNION of what
-- each names, so after: ['a','b'] means after BOTH, and the same instance
-- named twice - once by name, once by ref - is one edge.
function M.order_targets(spec, nodes)
  local specs = T.islist(spec) and spec or { spec }
  local hit = {}
  local seen = {}
  for i = 1, #specs do
    local one = specs[i]
    for _, b in ipairs(nodes) do
      if not seen[b.ref] and (b.ref == one or R.refname(b.ref) == one) then
        seen[b.ref] = true
        hit[#hit + 1] = b.ref
      end
    end
  end
  return hit
end

-- A PIN IS NOT A CONSTRAINT (section 7).
--
-- Constraints and bands are negotiable by definition - they are what
-- plugins and documents say they want, and the sort's job is to satisfy
-- them all. A pin is the host stating a structural invariant of its own
-- architecture, which is a different kind of claim and must not lose a tie
-- to a document.
--
-- So a pin PLACES the binding at the named end, and an ordering that would
-- move it away is `plugin_order_pinned` - rejected, not honoured into a
-- broken wrap.
local function applypin(order, edges, edgekeys, pin)
  if nil == pin or T.NULL == pin then return order end

  local out = {}
  for i = 1, #order do out[i] = order[i] end

  -- SORTED, not insertion order. A pin map is data - it can arrive from a
  -- host's own construction options in any order, and two names pinned to
  -- the same end are order-sensitive. A lua table has no order at all,
  -- which makes leaving it unstated worse here than anywhere else.
  for _, name in ipairs(T.keys(pin)) do
    local want = pin[name]
    local idx
    for i = 1, #out do
      if R.refname(out[i]) == name then idx = i break end
    end
    if nil ~= idx then
      -- `first`/`outermost` is index 1; `last`/`innermost` is the end.
      -- Section 6.2 makes the first chain binding outermost, which is why
      -- the vocabulary is positional and why the two spellings pair this
      -- way.
      local wantfirst = 'first' == want or 'outermost' == want
      local ref = table.remove(out, idx)
      if wantfirst then
        table.insert(out, 1, ref)
      else
        out[#out + 1] = ref
      end
    end
  end

  -- Now check that the placement did not break a constraint. This is the
  -- half that makes a pin a rejection rather than an override: the host
  -- wins on position, but it does not get to silently discard a
  -- relationship a plugin declared.
  local at = {}
  for i = 1, #out do at[out[i]] = i end
  for _, from in ipairs(edgekeys) do
    for _, to in ipairs(edges[from]) do
      if at[from] > at[to] then
        T.fail('plugin_order_pinned',
               'a pin would move a binding an ordering constrains: '
               .. from .. ' must precede ' .. to,
               T.map { before = from, after = to })
      end
    end
  end

  return out
end

-- `bindings` is a plain lua array of {ref=, pos=, order=} records: an
-- internal shape, never a corpus value, so it is not tagged.
function M.resolve_order(bindings, pin)
  local byref = {}
  local edges = {}
  local edgekeys = {}
  local indeg = {}
  for _, b in ipairs(bindings) do
    byref[b.ref] = b
    edges[b.ref] = {}
    edgekeys[#edgekeys + 1] = b.ref
    indeg[b.ref] = 0
  end
  table.sort(edgekeys)

  -- Constraints are edges. A constraint naming an ABSENT binding is
  -- satisfied VACUOUSLY (section 7) - a plugin ordered `after: 'test'`
  -- must load in a host with no test plugin. That is sdkgen's __after__
  -- behaviour, kept.
  for _, b in ipairs(bindings) do
    local block = T.ismap(b.order) and b.order or T.map {}
    -- An ABSENT constraint and an EMPTY LIST are both "no constraint".
    if M.order_declared(T.getv(block, 'after')) then
      for _, t in ipairs(M.order_targets(T.getv(block, 'after'), bindings)) do
        table.insert(edges[t], b.ref)
      end
    end
    if M.order_declared(T.getv(block, 'before')) then
      for _, t in ipairs(M.order_targets(T.getv(block, 'before'), bindings)) do
        table.insert(edges[b.ref], t)
      end
    end
  end

  for _, from in ipairs(edgekeys) do
    for _, to in ipairs(edges[from]) do
      indeg[to] = indeg[to] + 1
    end
  end

  -- Stable topological sort. Among ready nodes, band first (lower runs
  -- first), then `pos` - the position the DOCUMENT visibly states, not the
  -- order instances happened to load and not the incarnation `seq`.
  local out = {}
  local ready = {}
  for _, b in ipairs(bindings) do
    if 0 == indeg[b.ref] then ready[#ready + 1] = b end
  end

  while 0 < #ready do
    ready = T.stable_sort(ready, function(a, b)
      local ba, bb = M.order_band(a), M.order_band(b)
      if ba ~= bb then return ba < bb end
      return (a.pos or 0) < (b.pos or 0)
    end)
    local nxt = table.remove(ready, 1)
    out[#out + 1] = nxt.ref
    for _, to in ipairs(edges[nxt.ref]) do
      indeg[to] = indeg[to] - 1
      if 0 == indeg[to] then ready[#ready + 1] = byref[to] end
    end
  end

  if #out ~= #bindings then
    local placed = {}
    for _, r in ipairs(out) do placed[r] = true end
    local stuck = {}
    for _, b in ipairs(bindings) do
      if not placed[b.ref] then stuck[#stuck + 1] = b.ref end
    end
    T.fail('plugin_order_cycle',
           'before/after constraints cycle: ' .. table.concat(stuck, ' -> '),
           T.map { cycle = T.list(stuck) })
  end

  return applypin(out, edges, edgekeys, pin)
end

return M
