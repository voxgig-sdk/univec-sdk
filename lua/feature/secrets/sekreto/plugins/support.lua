-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lua/src/sekreto/plugins/support.lua)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- The pure helpers every store client shares, and nothing else.
--
-- This module REQUIRES NOTHING - no socket, no digest, no child process,
-- not even another sekreto module - so a plugin that needs only these
-- gets only these. secretspec and the boru CLI path both do: they want
-- `first` and `stripnewline` and no HTTP at all, and reaching those
-- through httpjson would put the whole HTTP/1.1 framing behind two kinds
-- that never open a socket.
--
-- It lives under plugins/ rather than in the core because only the ten
-- plugin kinds use any of it. The core's four built-ins read at most a
-- local file and need none of it.
--
-- The equivalents in the canonical port are spread across
-- typescript/plugins/httpjson.ts and typescript/plugins/support.ts; the
-- split into a separate module here is lua's, for the reason above.

local M = {}

--- The first candidate that is set and non-empty, or empty.
---
--- Walked with `select`, never with `ipairs` over a packed table: a nil
--- argument leaves a hole, and `ipairs` stops dead at the first one - so
--- `first(nil, os.getenv('AWS_ACCESS_KEY_ID'))` would answer empty with
--- the variable plainly set.
function M.first(...)
  local count = select('#', ...)

  for index = 1, count do
    local candidate = select(index, ...)
    if nil ~= candidate and '' ~= candidate then
      return candidate
    end
  end

  return ''
end

--- One trailing newline removed. A CLI prints the secret and a newline;
--- the newline is never part of the secret on purpose.
function M.stripnewline(text)
  if '\n' == text:sub(-1) then
    return text:sub(1, #text - 1)
  end
  return text
end

--- Never renewed: a configured token does not expire.
M.NEVER = math.maxinteger

--- Milliseconds since the epoch, near enough for token renewal.
function M.nowms()
  return os.time() * 1000
end

--- When a logged-in token must be renewed, from its expiry in seconds (a
--- JSON number, or a string as Azure IMDS sends it): now + max(seconds -
--- 60, 1). A missing or zero expiry means never renew.
function M.renewtime(expires)
  local seconds = 0

  if 'number' == type(expires) then
    seconds = expires
  elseif 'string' == type(expires) then
    seconds = tonumber(expires) or 0
  end

  if seconds ~= seconds or 0 >= seconds then
    return M.NEVER
  end

  return M.nowms() + math.floor(math.max(seconds - 60, 1) * 1000)
end

--- The `YYYYMMDDTHHMMSSZ` timestamp SigV4 wants, for now.
function M.awsnow()
  return os.date('!%Y%m%dT%H%M%SZ')
end

-- --------------------------------------------- percent-encoding
--
-- Here rather than with sigv4 because four plugins that sign nothing need
-- `uriescape` - azure, 1password, doppler and infisical - and reaching it
-- through sigv4 would put SHA-256 and HMAC behind all four. Moved
-- verbatim from what was src/sekreto/sigv4.lua: the sigv4 corpus group
-- is a known-answer test, so the bytes these two produce are pinned.

--- RFC 3986 escaping, which is stricter than the usual URL encoder: AWS
--- wants everything but the unreserved set escaped, with uppercase hex.
--- `!'()*` are escaped here and are not by JavaScript's own encoder.
function M.uriescape(text)
  local out = {}

  for index = 1, #text do
    local byte = text:byte(index)
    local ch = text:sub(index, index)

    if (65 <= byte and 90 >= byte) or
      (97 <= byte and 122 >= byte) or
      (48 <= byte and 57 >= byte) or
      45 == byte or 95 == byte or 46 == byte or 126 == byte
    then
      out[#out + 1] = ch
    else
      out[#out + 1] = string.format('%%%02X', byte)
    end
  end

  return table.concat(out)
end

local HEX = '0123456789abcdefABCDEF'

--- Percent-decode, and nothing else: `+` stays `+`, as on the wire, and a
--- malformed escape is kept literal.
function M.uridecode(text)
  local out = {}
  local index = 1

  while index <= #text do
    local ch = text:sub(index, index)

    if '%' == ch and index + 2 <= #text then
      local digits = text:sub(index + 1, index + 2)
      if nil ~= HEX:find(digits:sub(1, 1), 1, true) and
        nil ~= HEX:find(digits:sub(2, 2), 1, true)
      then
        out[#out + 1] = string.char(tonumber(digits, 16))
        index = index + 3
        goto continue
      end
    end

    out[#out + 1] = ch
    index = index + 1

    ::continue::
  end

  return table.concat(out)
end

return M
