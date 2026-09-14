-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lua/src/plugin/version.lua)
-- Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- Versions and ranges (section 11.2).
--
-- TWO FIELDS AND ONE PREDICATE. A capability declares `version`, a
-- concrete version. A requirement declares `range`. A requirement is
-- satisfied when the names match, the `match` passes, and the provider's
-- `version` falls inside the requirement's `range`.
--
-- That is the whole rule. There is no third field and no second comparison
-- - an earlier draft added a provider-side `compat` range, which left
-- three values and no statement of how they combine, and three defensible
-- readings of one declaration is worse than the ambiguity it was
-- introduced to fix.

local T = require 'feature.secrets.plugin.types'

local M = {}

-- A COMPONENT IS BOUNDED, and the bound is the model's, not the host
-- language's. Lua 5.4 integers are 64-bit and JavaScript's numbers stop
-- being exact past 2**53, so a twenty-digit component parsed to one value
-- here and a rounded one there. 2**31-1 is the smallest bound every target
-- language holds exactly, which makes it the model's.
M.COMPONENT_MAX = 2147483647

local function component(digits, whole, field)
  -- `tonumber` on twenty digits gives a FLOAT, not an error, and a float
  -- above the bound still compares above it - so the check fires on the
  -- imprecise value exactly as it does on an exact one.
  local value = tonumber(digits)
  if nil == value or M.COMPONENT_MAX < value then
    T.fail('plugin_bad_range',
           'version component out of range in ' .. whole .. ': ' .. digits,
           T.map { [field] = whole })
  end
  return math.tointeger(value) or value
end

-- `1`, `1.2` or `1.2.3`, fully anchored.
local function parts(text, whole, field)
  local pieces = {}
  for piece in (text .. '.'):gmatch('([^.]*)%.') do
    pieces[#pieces + 1] = piece
  end
  if 0 == #pieces or 3 < #pieces then return nil end
  local out = { 0, 0, 0 }
  for i, piece in ipairs(pieces) do
    if '' == piece or nil ~= piece:find('[^0-9]') then return nil end
    out[i] = component(piece, whole, field)
  end
  return out
end

-- Two forms and no more (section 11.2):
--
--   '2.1'    >= 2.1.0 and < 3.0.0
--   '~2.1'   >= 2.1.0 and < 2.2.0
function M.parse_range(range)
  if 'string' ~= type(range) or '' == range then
    T.fail('plugin_bad_range', 'invalid range: ' .. T.encode(range),
           T.map { range = range })
  end

  local tilde = '~' == range:sub(1, 1)
  local body = tilde and range:sub(2) or range
  local got = parts(body, range, 'range')
  if nil == got then
    T.fail('plugin_bad_range', 'invalid range: ' .. range,
           T.map { range = range })
  end

  local hi
  if tilde then
    hi = T.list { got[1], got[2] + 1, 0 }
  else
    hi = T.list { got[1] + 1, 0, 0 }
  end
  return T.map { lo = T.list { got[1], got[2], got[3] }, hi = hi }
end

function M.parse_version(version)
  if 'string' ~= type(version) then
    T.fail('plugin_bad_range', 'invalid version: ' .. T.encode(version),
           T.map { version = version })
  end
  local got = parts(version, version, 'version')
  if nil == got then
    T.fail('plugin_bad_range', 'invalid version: ' .. version,
           T.map { version = version })
  end
  return got
end

local function cmp(a, b)
  for i = 1, 3 do
    local x = a[i] or 0
    local y = b[i] or 0
    if x ~= y then return x < y and -1 or 1 end
  end
  return 0
end

-- The one satisfaction predicate: lo <= version < hi.
function M.satisfies(version, range)
  local v = M.parse_version(version)
  local r = M.parse_range(range)
  return 0 <= cmp(v, r.lo) and 0 > cmp(v, r.hi)
end

-- satisfies for the internal callers that treat an unparseable version or
-- range as "does not satisfy" - Capability and Graph, both of which run
-- over data the corpus has already admitted.
function M.satisfiesq(version, range)
  local ok, out = pcall(M.satisfies, version, range)
  return ok and out or false
end

-- The version triple as a comparable key, for the capability rank.
function M.version_parts(text)
  local out = {}
  for piece in (tostring(text) .. '.'):gmatch('([^.]*)%.') do
    out[#out + 1] = tonumber(piece) or 0
  end
  return out
end

M.version_cmp = cmp

return M
