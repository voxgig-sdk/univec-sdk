-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lua/src/sekreto/plugins/json.lua)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- sekreto's own JSON, because Lua has none.
--
-- Lua 5.4's whole standard library is basic, coroutine, package, string,
-- utf8, table, math, io, os and debug - so a JSON parser is written here
-- rather than depended on. Two properties the vendor payloads need and a
-- naive table would not give: object keys keep their INSERTION ORDER (an
-- AWS payload's field order is signed, so it cannot be re-ordered by a
-- hash table), and a parse FAILURE is distinguishable from the literal
-- `null` (fetchjson must tell "this text is not JSON" from "this text is
-- the JSON null", and Lua's `nil` cannot say both).
--
-- A port of typescript's JSON handling, which is canonical.

local M = {}

-- The JSON null. A Lua nil cannot live in a table and cannot be returned
-- distinguishably, so null is a sentinel of its own.
M.NULL = setmetatable({}, { __tostring = function() return 'null' end })

local ARRMT = { __sekretojson = 'arr' }
local OBJMT = { __sekretojson = 'obj' }

-- The recursion bound. A response body arrives before any trust check has
-- been made, so `[[[[[...` must fail rather than take the process down.
local MAXDEPTH = 128

--- A JSON array, from a Lua sequence.
function M.arr(items)
  return setmetatable({ items = items or {} }, ARRMT)
end

--- A JSON object, from a list of {key, value} pairs, in that order.
function M.obj(pairlist)
  local keys = {}
  local vals = {}

  for _, pair in ipairs(pairlist or {}) do
    if nil == vals[pair[1]] then
      keys[#keys + 1] = pair[1]
    end
    vals[pair[1]] = pair[2]
  end

  return setmetatable({ keys = keys, vals = vals }, OBJMT)
end

function M.isarr(val)
  return 'table' == type(val) and ARRMT == getmetatable(val)
end

function M.isobj(val)
  return 'table' == type(val) and OBJMT == getmetatable(val)
end

function M.isnull(val)
  return M.NULL == val
end

--- Set one key on an object, keeping insertion order.
function M.set(object, key, value)
  if nil == object.vals[key] then
    object.keys[#object.keys + 1] = key
  end
  object.vals[key] = value
  return object
end

--- Walk nested objects, stopping at the first missing step. Returns nil.
function M.dig(val, ...)
  local at = val

  for _, key in ipairs({ ... }) do
    if not M.isobj(at) then
      return nil
    end
    at = at.vals[key]
    if nil == at then
      return nil
    end
  end

  return at
end

--- The value as a string, or nil for anything else.
function M.asstr(val)
  return 'string' == type(val) and val or nil
end

--- The value as a number, or nil for anything else.
function M.asnum(val)
  return 'number' == type(val) and val or nil
end

--- The value as an array's item list, or nil.
function M.asarr(val)
  return M.isarr(val) and val.items or nil
end

--- The value as an object, or nil.
function M.asobj(val)
  return M.isobj(val) and val or nil
end

--- Render a number the same way in every port: 5.0 prints as 5.
function M.numstr(val)
  if val ~= val or math.huge == val or -math.huge == val then
    return 'null'
  end

  if math.type(val) == 'integer' then
    return string.format('%d', val)
  end

  if val == math.floor(val) and math.abs(val) < 9007199254740992.0 then
    return string.format('%d', math.tointeger(val) or val)
  end

  return (string.format('%.17g', val))
end

--- Printable text, or nil. A JSON null yields nil, so a null field is a
--- miss rather than the string "null".
function M.text(val)
  if nil == val or M.NULL == val then
    return nil
  end
  if 'string' == type(val) then
    return val
  end
  if 'number' == type(val) then
    return M.numstr(val)
  end
  if 'boolean' == type(val) then
    return val and 'true' or 'false'
  end
  return nil
end

--- Render a string as a JSON string literal.
function M.quote(text)
  local out = { '"' }

  for index = 1, #text do
    local ch = text:sub(index, index)
    local byte = ch:byte()

    if '"' == ch then
      out[#out + 1] = '\\"'
    elseif '\\' == ch then
      out[#out + 1] = '\\\\'
    elseif '\n' == ch then
      out[#out + 1] = '\\n'
    elseif '\r' == ch then
      out[#out + 1] = '\\r'
    elseif '\t' == ch then
      out[#out + 1] = '\\t'
    elseif 0x20 > byte then
      out[#out + 1] = string.format('\\u%04x', byte)
    else
      out[#out + 1] = ch
    end
  end

  out[#out + 1] = '"'
  return table.concat(out)
end

--- Compact JSON text: no spaces, no newlines, keys in insertion order.
function M.stringify(val)
  if nil == val or M.NULL == val then
    return 'null'
  end

  local kind = type(val)

  if 'boolean' == kind then
    return val and 'true' or 'false'
  end

  if 'number' == kind then
    return M.numstr(val)
  end

  if 'string' == kind then
    return M.quote(val)
  end

  if M.isarr(val) then
    local parts = {}
    for index, item in ipairs(val.items) do
      parts[index] = M.stringify(item)
    end
    return '[' .. table.concat(parts, ',') .. ']'
  end

  if M.isobj(val) then
    local parts = {}
    for index, key in ipairs(val.keys) do
      parts[index] = M.quote(key) .. ':' .. M.stringify(val.vals[key])
    end
    return '{' .. table.concat(parts, ',') .. '}'
  end

  return 'null'
end

-- ---- the parser ------------------------------------------------------
--
-- Every failure below raises inside a pcall that `parse` owns, so no error
-- ever escapes it: a malformed body is answered with nil, and the caller
-- decides whether that is a miss or a failure.

local parsevalue

local WS = { [' '] = true, ['\t'] = true, ['\n'] = true, ['\r'] = true }

local function skipws(text, pos)
  local at = pos
  while at <= #text and WS[text:sub(at, at)] do
    at = at + 1
  end
  return at
end

local function bad(why)
  error({ json = true, why = why }, 0)
end

local function parseword(text, pos, word, value)
  if word ~= text:sub(pos, pos + #word - 1) then
    bad('literal')
  end
  return value, pos + #word
end

local HEX = '0123456789abcdefABCDEF'

local function parsestring(text, pos)
  if '"' ~= text:sub(pos, pos) then
    bad('string')
  end

  local at = pos + 1
  local out = {}

  while at <= #text do
    local ch = text:sub(at, at)

    if '"' == ch then
      return table.concat(out), at + 1
    end

    if '\\' ~= ch then
      out[#out + 1] = ch
      at = at + 1
    else
      local escape = text:sub(at + 1, at + 1)
      at = at + 2

      if '"' == escape then
        out[#out + 1] = '"'
      elseif '\\' == escape then
        out[#out + 1] = '\\'
      elseif '/' == escape then
        out[#out + 1] = '/'
      elseif 'b' == escape then
        out[#out + 1] = '\b'
      elseif 'f' == escape then
        out[#out + 1] = '\f'
      elseif 'n' == escape then
        out[#out + 1] = '\n'
      elseif 'r' == escape then
        out[#out + 1] = '\r'
      elseif 't' == escape then
        out[#out + 1] = '\t'
      elseif 'u' == escape then
        local digits = text:sub(at, at + 3)
        if 4 ~= #digits then
          bad('escape')
        end
        for index = 1, 4 do
          if nil == HEX:find(digits:sub(index, index), 1, true) then
            bad('escape')
          end
        end
        -- One UTF-16 code unit, appended as UTF-8. No surrogate-pair
        -- recombination, in this port or any other.
        out[#out + 1] = utf8.char(tonumber(digits, 16))
        at = at + 4
      else
        bad('escape')
      end
    end
  end

  bad('string')
end

local function parseobj(text, pos, depth)
  local at = skipws(text, pos + 1)
  local object = M.obj({})

  if '}' == text:sub(at, at) then
    return object, at + 1
  end

  while true do
    at = skipws(text, at)

    local key
    key, at = parsestring(text, at)

    at = skipws(text, at)
    if ':' ~= text:sub(at, at) then
      bad('object')
    end

    local value
    value, at = parsevalue(text, at + 1, depth + 1)

    M.set(object, key, value)

    at = skipws(text, at)
    local ch = text:sub(at, at)

    if '}' == ch then
      return object, at + 1
    end

    if ',' ~= ch then
      bad('object')
    end

    at = at + 1
  end
end

local function parsearr(text, pos, depth)
  local at = skipws(text, pos + 1)
  local items = {}

  if ']' == text:sub(at, at) then
    return M.arr(items), at + 1
  end

  while true do
    local value
    value, at = parsevalue(text, at, depth + 1)
    items[#items + 1] = value

    at = skipws(text, at)
    local ch = text:sub(at, at)

    if ']' == ch then
      return M.arr(items), at + 1
    end

    if ',' ~= ch then
      bad('array')
    end

    at = at + 1
  end
end

local NUMCHARS = '0123456789+-.eE'

local function parsenumber(text, pos)
  local at = pos

  while at <= #text and nil ~= NUMCHARS:find(text:sub(at, at), 1, true) do
    at = at + 1
  end

  local value = tonumber(text:sub(pos, at - 1))

  -- 1e999 parses to infinity, which JSON has no literal for and which
  -- would later blow up a token-expiry computation.
  if nil == value or value ~= value or math.huge == value or -math.huge == value then
    bad('number')
  end

  return value, at
end

parsevalue = function(text, pos, depth)
  if MAXDEPTH < depth then
    bad('depth')
  end

  local at = skipws(text, pos)
  local ch = text:sub(at, at)

  if '' == ch then
    bad('eof')
  end

  if '{' == ch then
    return parseobj(text, at, depth)
  end

  if '[' == ch then
    return parsearr(text, at, depth)
  end

  if '"' == ch then
    return parsestring(text, at)
  end

  if 't' == ch then
    return parseword(text, at, 'true', true)
  end

  if 'f' == ch then
    return parseword(text, at, 'false', false)
  end

  if 'n' == ch then
    return parseword(text, at, 'null', M.NULL)
  end

  return parsenumber(text, at)
end

--- Parse JSON text. Returns the value, or nil when the text is not JSON.
--- The literal `null` parses to M.NULL, which is NOT nil - that is the
--- whole reason the sentinel exists.
function M.parse(text)
  if 'string' ~= type(text) or '' == text then
    return nil
  end

  local ok, value, at = pcall(parsevalue, text, 1, 1)
  if not ok then
    return nil
  end

  if #text >= skipws(text, at) then
    return nil
  end

  return value
end

return M
