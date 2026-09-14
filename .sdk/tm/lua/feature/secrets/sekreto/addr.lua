-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lua/src/sekreto/addr.lua)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- Address checking: core, never a plugin.
--
-- Every network provider routes its configured address through
-- `checkaddr` before a socket is opened, and every refusal names the
-- address through `safeaddr`.
--
-- The address is read by hand, in the same handful of steps in every
-- port, rather than by each platform's URL parser. That is deliberate.
-- Twelve parsers disagree about malformed input - where userinfo ends,
-- whether `0177.0.0.1` is loopback, what an unclosed bracket means - and
-- a check that answers differently in different ports is not a check.
--
-- The rule this parse obeys, and the reason it can be trusted: it is
-- never more permissive than the transport that will dial the address.
-- It ends the authority at `/`, `?` or `#` only, so a client that also
-- breaks on `\` can only ever see a SHORTER host than this does. It
-- refuses userinfo outright rather than locating its end. It compares the
-- host literally, so a numeric form no parser here agrees on is refused
-- rather than guessed at.

local err = require('feature.secrets.sekreto.err')

local M = {}

local function lowerascii(text)
  return (text:gsub('[A-Z]', function(ch) return string.char(ch:byte() + 32) end))
end

--- An address with any userinfo replaced by `[redacted]`, for messages.
---
--- Every refusal below names the address it refused, and one of them
--- fires precisely because the address carries a credential - so printing
--- it verbatim would write the password to stderr and into the logs. It
--- cannot be cleaned up afterwards either: that password was never
--- resolved as a secret, so `redact()` has never seen it and never will.
function M.safeaddr(addr)
  local mark = addr:find('://', 1, true)
  if not mark then
    return addr
  end

  local rest = addr:sub(mark + 3)
  local stop = rest:find('[/?#]')
  local authority = stop and rest:sub(1, stop - 1) or rest

  local at = authority:find('@[^@]*$')
  if not at then
    return addr
  end

  return addr:sub(1, mark + 2) .. '[redacted]' .. addr:sub(mark + 3 + at - 1)
end

--- Refuse to send a secret-bearing credential in the clear.
---
--- A vault API is HTTPS in any real deployment; plaintext is a dev-mode
--- convenience. Loopback stays allowed: that is `vault server -dev`,
--- `boru vault serve`, and this repository's own test harness.
function M.checkaddr(addr)
  local scheme

  if 'https://' == addr:sub(1, 8) then
    scheme = 'https://'
  elseif 'http://' == addr:sub(1, 7) then
    scheme = 'http://'
  else
    err.fail('sekreto: not an http(s) address: ' .. M.safeaddr(addr))
  end

  local rest = addr:sub(#scheme + 1)
  local stop = rest:find('[/?#]')
  local authority = stop and rest:sub(1, stop - 1) or rest

  -- Userinfo is refused outright rather than parsed around, and on https
  -- as well as http. No store this library speaks authenticates by
  -- userinfo - they take a token or a signature - so an address carrying
  -- one is a mistake at best. At worst it is the attack this whole
  -- function exists to stop: `http://localhost:8200@evil.example.com/` is
  -- a request to evil.example.com that reads, to anything that splits the
  -- authority on ':', as loopback.
  if nil ~= authority:find('@', 1, true) then
    err.fail('sekreto: refusing an address with embedded credentials: ' .. M.safeaddr(addr))
  end

  -- An opening bracket with no closing one is not an address at all.
  if '[' == authority:sub(1, 1) and nil == authority:find(']', 1, true) then
    err.fail('sekreto: not a valid http(s) address: ' .. M.safeaddr(addr))
  end

  if 'https://' == scheme then
    return
  end

  -- A bracketed IPv6 literal keeps its brackets: splitting the authority
  -- on the first colon would yield '[', which could never match.
  local host
  if '[' == authority:sub(1, 1) then
    host = authority:sub(1, authority:find(']', 1, true))
  else
    local colon = authority:find(':', 1, true)
    host = colon and authority:sub(1, colon - 1) or authority
  end
  host = lowerascii(host)

  -- Four literals, and nothing is normalised: `0177.0.0.1`, `2130706433`,
  -- `127.0.0.2` and `[::ffff:127.0.0.1]` are all refused.
  if 'localhost' == host or '127.0.0.1' == host or '::1' == host or '[::1]' == host then
    return
  end

  err.fail('sekreto: refusing to send a token in plaintext to ' ..
    M.safeaddr(addr) .. ' (use https)')
end

--- A URL without its query string, for a message that must not leak one.
function M.bare(url)
  local mark = url:find('?', 1, true)
  return mark and url:sub(1, mark - 1) or url
end

return M
