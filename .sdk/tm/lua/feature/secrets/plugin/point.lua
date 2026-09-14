-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lua/src/plugin/point.lua)
-- Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- Extension points (section 6). Three kinds, chosen because they are what
-- the two existing systems actually needed, and no more.
--
-- A PLUGIN NEVER MUTATES THE HOST. That inversion is what makes
-- deactivation possible: sdkgen's `utility.fetcher = wrapped` is not
-- undoable, but "this instance holds slot 3 of the request chain" is
-- undoable in O(1). OSGi named it the whiteboard pattern in 2004, in a
-- paper called *Listeners Considered Harmful*, and for exactly this
-- reason.

local T = require 'feature.secrets.plugin.types'

local M = {}

-- Section 6.1: "fan-out" is not one answer but four. In a language with
-- asynchrony, "call every binding" hides a decision - start them all and
-- wait, await each in turn, or do not wait - and a design that leaves it
-- unsaid gets four different answers from four ports, in the concurrency
-- behaviour of production code no corpus entry happens to cover.
M.MODES = { 'emit', 'parallel', 'serial', 'bail' }

-- Fan-out. Return values are ignored except in `bail`.
function M.point_emit(bindings, mode, arg)
  if 'bail' == mode then
    -- Stops at the first binding that RETURNS A VALUE - the "handled,
    -- stop" case. A `nil` RETURN DECLINES (section 6.1): lua has one way
    -- to say nothing, and the model's rule is written to that rather than
    -- to JavaScript's null/undefined pair. Not truthiness - `false` is a
    -- value.
    for _, b in ipairs(bindings) do
      local v = b.fn(nil, arg)
      -- BOTH SPELLINGS OF NOTHING DECLINE. A lua callback returns `nil`,
      -- and a callback handing back a JSON null returns `T.NULL` - the
      -- sentinel this port uses because a table cannot store a nil. The
      -- model's rule is that NULL declines (`point/bail#null-declines`
      -- pins a provider configured with `value: null` letting the next one
      -- answer), so a port that stopped on the sentinel would answer null
      -- where every other port answers "B".
      if nil ~= v and T.NULL ~= v then return v end
    end
    return nil
  end

  local errors = {}
  for _, b in ipairs(bindings) do
    local ok, err = pcall(b.fn, nil, arg)
    if not ok then
      -- `emit` raises synchronously; the collecting modes gather.
      if 'emit' == mode then error(err, 0) end
      errors[#errors + 1] = T.message(err)
    end
  end
  if 'emit' == mode then return nil end
  return T.list(errors)
end

-- Composition: b1(b2(b3(base))), FIRST BINDING OUTERMOST (section 6.2).
--
-- Recomputed by the host whenever the live set changes, and cached between
-- changes. Plugins receive `next` as an argument; they never see or store
-- the previous value of anything. A plugin that stashes `next` and calls
-- it after deactivation is a bug the host cannot prevent, and this says so
-- rather than pretending otherwise.
function M.compose(bindings, base)
  local nxt = base
  for i = #bindings, 1, -1 do
    -- Fresh locals per iteration, so each layer closes over its own pair -
    -- lua gives that for free where ruby's blocks do not.
    local fn = bindings[i].fn
    local inner = nxt
    nxt = function(...) return fn(inner, ...) end
  end
  return nxt
end

-- At most one live implementation (section 6.3). The winner is the highest
-- band, ties broken by ref sort, and THE LOSERS ARE VISIBLE rather than
-- silently ignored.
function M.point_provider(bindings, spec)
  if 0 == #bindings then
    return { winner = nil, shadowed = T.list {} }
  end

  if T.truthy(T.getv(spec, 'exclusive')) and 1 < #bindings then
    local refs = {}
    for _, b in ipairs(bindings) do refs[#refs + 1] = b.ref end
    table.sort(refs)
    T.fail('plugin_point_exclusive',
           'point is exclusive and has ' .. #bindings .. ' bindings: '
           .. table.concat(refs, ', '),
           T.map { refs = T.list(refs) })
  end

  local ranked = T.stable_sort(bindings, function(a, b)
    if a.band ~= b.band then return a.band > b.band end
    return a.ref < b.ref
  end)
  local shadowed = {}
  for i = 2, #ranked do shadowed[#shadowed + 1] = ranked[i].ref end
  return { winner = ranked[1], shadowed = T.list(shadowed) }
end

return M
