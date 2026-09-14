-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lua/src/plugin/types.lua)
-- Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- Shared types and the value helpers every module reads data through.
--
-- Deliberately small: the design's section 19 budget says the library owns
-- naming, configuration, lifecycle, ordering, binding and teardown, and
-- nothing else.
--
-- LUA HAS ONE COMPOSITE TYPE AND NO NULL, and both are corpus-visible:
--
--   * A TABLE IS BOTH A MAP AND A LIST. `{}` is neither and both, so the
--     parser TAGS every table it builds with a metatable and this file
--     builds every table through `map()` or `list()`. An untagged table
--     would read as whichever the first test happened to ask about.
--
--   * `t[k] = nil` DELETES the key, so a JSON `null` cannot be stored as
--     one. `NULL` is a unique sentinel: `t[k] == nil` is ABSENT and
--     `t[k] == NULL` is a present null, which is exactly the distinction
--     `__UNDEF__` and `__NULL__` assert.

local M = {}

-- Section 5.1's seven statuses, and no more. A port that adds an eighth is
-- diverging. `loading` and `closing` are observable only from inside a
-- callback or from another thread.
M.STATUSES = { 'declared', 'loaded', 'pending', 'live', 'failed',
               'loading', 'closing' }

-- Section 12's detail fields, IN THIS FIXED ORDER.
--
-- The order is part of the contract, not a formatting preference. An
-- earlier draft named six fields while other sections promised diagnostics
-- that had nowhere to go, which would have left each port inventing its
-- own order and breaking message parity.
M.DETAIL_ORDER = {
  'host', 'ref', 'name', 'tag', 'point', 'key', 'capability',
  'range', 'version', 'match', 'candidates', 'cycle', 'holders',
  'refs', 'path', 'cause',
}

-- The present-null sentinel. A table rather than a string, so nothing a
-- document could contain can be mistaken for it.
M.NULL = setmetatable({}, { __tostring = function() return 'null' end })

M.MAP_MT = { __jsontype = 'map' }
M.LIST_MT = { __jsontype = 'list' }

function M.map(t)
  return setmetatable(t or {}, M.MAP_MT)
end

function M.list(t)
  return setmetatable(t or {}, M.LIST_MT)
end

function M.ismap(v)
  return 'table' == type(v) and getmetatable(v) == M.MAP_MT
end

function M.islist(v)
  return 'table' == type(v) and getmetatable(v) == M.LIST_MT
end

function M.isnull(v)
  return v == M.NULL
end

-- Ruby's truthiness, which is not lua's: `nil` and `false` are false here
-- too, but a PRESENT NULL must also be false, and `0` and `''` must be
-- true (lua already agrees about those two).
function M.truthy(v)
  return nil ~= v and false ~= v and M.NULL ~= v
end

-- The value at a key: nil when absent, NULL when present-and-null.
function M.get(t, k)
  if not M.ismap(t) then return nil end
  return t[k]
end

-- PRESENCE, which is what distinguishes an authored null from absence.
function M.has(t, k)
  if not M.ismap(t) then return false end
  return nil ~= t[k]
end

-- The value at a key with NULL flattened to nil, for the callers that
-- genuinely do not care which they got.
function M.getv(t, k)
  local v = M.get(t, k)
  if M.NULL == v then return nil end
  return v
end

function M.at(l, i)
  if not M.islist(l) then return nil end
  return l[i]
end

function M.len(l)
  if not M.islist(l) then return 0 end
  return #l
end

-- The keys of a map, SORTED. `pairs` has no defined order in lua, so every
-- walk of a map in this port goes through here.
function M.keys(t)
  local out = {}
  if not M.ismap(t) then return out end
  for k in pairs(t) do out[#out + 1] = k end
  table.sort(out)
  return out
end

function M.sortstrings(l)
  local out = {}
  for i = 1, #l do out[i] = l[i] end
  table.sort(out)
  return out
end

-- STABLE sort by a comparator. `table.sort` is NOT stable and the
-- canonical's comparators fall through to a `pos` or ref tie-break, so
-- every sort in this port decorates with the original index and uses it as
-- the last tier.
function M.stable_sort(l, less)
  local decorated = {}
  for i = 1, #l do decorated[i] = { item = l[i], at = i } end
  table.sort(decorated, function(a, b)
    if less(a.item, b.item) then return true end
    if less(b.item, a.item) then return false end
    return a.at < b.at
  end)
  local out = {}
  for i = 1, #decorated do out[i] = decorated[i].item end
  return out
end

function M.copy(v)
  if M.islist(v) then
    local out = {}
    for i = 1, #v do out[i] = M.copy(v[i]) end
    return M.list(out)
  end
  if M.ismap(v) then
    local out = {}
    for k, x in pairs(v) do out[k] = M.copy(x) end
    return M.map(out)
  end
  return v
end

-- JSON equality: same type, then same value.
--
-- `true == 1` and `1 == '1'` are BOTH FALSE in lua, which is what
-- `capability/match` needs and what php, perl and lua were each expected
-- to get wrong. Lua gets it right for the same reason ruby does: no
-- coercion across types in `==`.
function M.same(a, b)
  if M.ismap(a) or M.ismap(b) then
    if not (M.ismap(a) and M.ismap(b)) then return false end
    local ka, kb = M.keys(a), M.keys(b)
    if #ka ~= #kb then return false end
    for i = 1, #ka do
      if ka[i] ~= kb[i] then return false end
      if not M.same(a[ka[i]], b[ka[i]]) then return false end
    end
    return true
  end
  if M.islist(a) or M.islist(b) then
    if not (M.islist(a) and M.islist(b)) then return false end
    if #a ~= #b then return false end
    for i = 1, #a do
      if not M.same(a[i], b[i]) then return false end
    end
    return true
  end
  return a == b
end

-- The error type. Every error carries a section 12 code; ports compare by
-- CODE and never by message, because wording is a port's own business and
-- pinning the words would make every translation a corpus change.
local Error = {}
Error.__index = Error
Error.__tostring = function(e) return e.message end
M.Error = Error

-- `plugin/<code>: <text> [<key>=<value> ...]`
--
-- Values render as COMPACT JSON, so a value containing a space or a
-- bracket cannot break the parse, and a list renders as a JSON array. The
-- bracket is absent entirely when no field applies.
function M.formaterror(code, text, details)
  local parts = {}
  for _, k in ipairs(M.DETAIL_ORDER) do
    if M.has(details, k) then
      parts[#parts + 1] = k .. '=' .. M.encode(details[k])
    end
  end
  local tail = 0 == #parts and '' or (' [' .. table.concat(parts, ' ') .. ']')
  return 'plugin/' .. code .. ': ' .. text .. tail
end

function M.fail(code, text, details)
  error(setmetatable({
    code = code,
    text = text,
    details = details,
    message = M.formaterror(code, text, details),
  }, Error), 0)
end

-- The section 12 code of an error, or '' for one this library did not
-- raise. The corpus compares by code, so the driver needs one place that
-- knows how to read it.
function M.codeof(err)
  if 'table' == type(err) and getmetatable(err) == Error then
    return err.code
  end
  return ''
end

function M.message(err)
  if 'table' == type(err) and getmetatable(err) == Error then
    return err.message
  end
  return tostring(err)
end

-- A detail map, spelled once rather than at forty call sites.
function M.details(pairs_)
  return M.map(pairs_)
end

-- Compact JSON. Set here rather than in json.lua so that `formaterror` -
-- which every module reaches - does not pull the parser in behind it.
function M.encode(v)
  if nil == v or M.NULL == v then return 'null' end
  local t = type(v)
  if 'boolean' == t then return v and 'true' or 'false' end
  if 'number' == t then
    if math.type(v) == 'integer' then return tostring(v) end
    -- An integral float prints without a fractional part, so a `pos` of 3
    -- renders as `3` and not `3.0` - JSON has one number type and the
    -- corpus writes them as it means them.
    if v == math.floor(v) and math.abs(v) < 1e15 then
      return string.format('%d', v)
    end
    return tostring(v)
  end
  if 'string' == t then
    local out = v:gsub('[\\"]', '\\%0'):gsub('\n', '\\n'):gsub('\r', '\\r')
        :gsub('\t', '\\t')
    return '"' .. out .. '"'
  end
  if M.islist(v) then
    local parts = {}
    for i = 1, #v do parts[i] = M.encode(v[i]) end
    return '[' .. table.concat(parts, ',') .. ']'
  end
  if M.ismap(v) then
    local parts = {}
    for _, k in ipairs(M.keys(v)) do
      parts[#parts + 1] = M.encode(k) .. ':' .. M.encode(v[k])
    end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  -- A host object published through `exports` (section 11) - the library
  -- never inspects one and nothing in the corpus compares one.
  return '"(opaque)"'
end

return M
