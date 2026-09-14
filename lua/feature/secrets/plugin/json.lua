-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lua/src/plugin/json.lua)
-- Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- The JSON parser, and the only one this port has.
--
-- NO LUAROCKS, NO DKJSON, NO CJSON (section 16). The library is allowed
-- exactly one runtime dependency, `voxgig/struct`, which has no lua port;
-- everything else is the standard library. Parsing the corpus is a hundred
-- and fifty lines, and a hundred and fifty lines is cheaper than a rock
-- every embedding host has to install.
--
-- EVERY TABLE IT BUILDS IS TAGGED (types.map / types.list) and every JSON
-- null becomes `types.NULL`. That is what lets this port tell `{}` from
-- `[]` and an absent key from a null one - two distinctions the corpus
-- draws and a plain lua table cannot.

local T = require 'feature.secrets.plugin.types'

local M = {}

local function skipws(s, at)
  while at <= #s do
    local c = s:sub(at, at)
    if ' ' ~= c and '\t' ~= c and '\n' ~= c and '\r' ~= c then break end
    at = at + 1
  end
  return at
end

local parsevalue

local function parsestring(s, at)
  if '"' ~= s:sub(at, at) then
    error('expected a string at ' .. at, 0)
  end
  at = at + 1
  local out = {}
  while at <= #s do
    local c = s:sub(at, at)
    at = at + 1
    if '"' == c then
      return table.concat(out), at
    end
    if '\\' == c then
      local e = s:sub(at, at)
      at = at + 1
      if '"' == e then out[#out + 1] = '"'
      elseif '\\' == e then out[#out + 1] = '\\'
      elseif '/' == e then out[#out + 1] = '/'
      elseif 'b' == e then out[#out + 1] = '\b'
      elseif 'f' == e then out[#out + 1] = '\f'
      elseif 'n' == e then out[#out + 1] = '\n'
      elseif 'r' == e then out[#out + 1] = '\r'
      elseif 't' == e then out[#out + 1] = '\t'
      elseif 'u' == e then
        local hex = s:sub(at, at + 3)
        at = at + 4
        local code = tonumber(hex, 16)
        if nil == code then error('bad \\u escape at ' .. at, 0) end
        -- A surrogate PAIR is two escapes; lua 5.4's utf8.char takes the
        -- joined code point, so the pair is joined here.
        if 0xD800 <= code and code < 0xDC00 and '\\u' == s:sub(at, at + 1) then
          local low = tonumber(s:sub(at + 2, at + 5), 16)
          if nil ~= low and 0xDC00 <= low and low < 0xE000 then
            at = at + 6
            code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
          end
        end
        out[#out + 1] = utf8.char(code)
      else
        error('bad escape at ' .. at, 0)
      end
    else
      out[#out + 1] = c
    end
  end
  error('unterminated string', 0)
end

local function parsemap(s, at)
  local out = {}
  at = skipws(s, at + 1)
  if '}' == s:sub(at, at) then
    return T.map(out), at + 1
  end
  while true do
    at = skipws(s, at)
    local key
    key, at = parsestring(s, at)
    at = skipws(s, at)
    if ':' ~= s:sub(at, at) then error("expected ':' at " .. at, 0) end
    at = skipws(s, at + 1)
    local value
    value, at = parsevalue(s, at)
    out[key] = value
    at = skipws(s, at)
    local c = s:sub(at, at)
    if ',' == c then
      at = at + 1
    elseif '}' == c then
      return T.map(out), at + 1
    else
      error("expected ',' or '}' at " .. at, 0)
    end
  end
end

local function parselist(s, at)
  local out = {}
  at = skipws(s, at + 1)
  if ']' == s:sub(at, at) then
    return T.list(out), at + 1
  end
  while true do
    at = skipws(s, at)
    local value
    value, at = parsevalue(s, at)
    out[#out + 1] = value
    at = skipws(s, at)
    local c = s:sub(at, at)
    if ',' == c then
      at = at + 1
    elseif ']' == c then
      return T.list(out), at + 1
    else
      error("expected ',' or ']' at " .. at, 0)
    end
  end
end

local function literal(s, at, word, value)
  if word ~= s:sub(at, at + #word - 1) then
    error('bad literal at ' .. at, 0)
  end
  return value, at + #word
end

parsevalue = function(s, at)
  local c = s:sub(at, at)
  if '{' == c then return parsemap(s, at) end
  if '[' == c then return parselist(s, at) end
  if '"' == c then return parsestring(s, at) end
  if 't' == c then return literal(s, at, 'true', true) end
  if 'f' == c then return literal(s, at, 'false', false) end
  if 'n' == c then return literal(s, at, 'null', T.NULL) end

  local body = s:match('^%-?%d+%.?%d*[eE]?[-+]?%d*', at)
  if nil == body or '' == body then
    error('unexpected input at ' .. at, 0)
  end
  local n = tonumber(body)
  if nil == n then error('bad number at ' .. at, 0) end
  return n, at + #body
end

function M.parse(text)
  local at = skipws(text, 1)
  local value
  value, at = parsevalue(text, at)
  at = skipws(text, at)
  if at <= #text then
    error('trailing input at ' .. at, 0)
  end
  return value
end

M.encode = T.encode

return M
