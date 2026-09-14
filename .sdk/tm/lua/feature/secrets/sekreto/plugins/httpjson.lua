-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lua/src/sekreto/plugins/httpjson.lua)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- HTTP/1.1, framed by hand, plus the one JSON round-trip every store
-- client makes - the HTTP half of the plugins, in one place and OUTSIDE
-- the core. A chain of built-in kinds never requires this file.
--
-- Lua has no client, and the dependency rule covers cryptographic
-- transport and nothing else - so the request line, the headers, the
-- length-counted and chunked bodies are all written here. The bytes go
-- through src/sekreto/plugins/net.lua to a socket the helper owns;
-- nothing in this file knows whether that socket is TLS.
--
-- Everything the transport contract asks of a round-trip is here:
--
--   * ten seconds on the whole exchange, and an 8 MiB body cap, read one
--     byte past the bound so that exceeding it is detectable;
--   * redirects are NEVER followed - a followed redirect carries
--     X-Vault-Token to a host checkaddr never saw, and can downgrade
--     https to http;
--   * proxies are ignored, because there is no library reading
--     http_proxy: the socket is opened to the address that was checked.
--     A proxy has sent a Vault token in the clear before.
--
-- A port of typescript/plugins/httpjson.ts and of rust/src/http.rs, which
-- is the model for a hand-framed port.

local err = require('feature.secrets.sekreto.err')
local addr = require('feature.secrets.sekreto.addr')
local net = require('feature.secrets.sekreto.plugins.net')
local json = require('feature.secrets.sekreto.plugins.json')

local M = {}

M.TIMEOUT = 10000
M.MAXBODY = 8 * 1024 * 1024

--- Split a URL into the pieces a request needs.
---
--- IPv6 is why the port is found by searching BACKWARDS for `:`: a
--- literal's own colons would otherwise be read as one. The BARE host
--- (brackets stripped) is what is dialled and what the certificate is
--- checked against; the BRACKETED form is what goes in `Host:`.
function M.split(url)
  local scheme, rest

  if 'https://' == url:sub(1, 8) then
    scheme, rest = 'https', url:sub(9)
  elseif 'http://' == url:sub(1, 7) then
    scheme, rest = 'http', url:sub(8)
  else
    err.fail('sekreto: not an http(s) address: ' .. addr.safeaddr(url))
  end

  local stop = rest:find('[/?#]')
  local authority = stop and rest:sub(1, stop - 1) or rest
  local target = stop and rest:sub(stop) or '/'

  if '?' == target:sub(1, 1) or '#' == target:sub(1, 1) then
    target = '/' .. target
  end

  local host = authority
  local port = ('https' == scheme) and 443 or 80
  local explicit = false

  if '[' == authority:sub(1, 1) then
    local close = authority:find(']', 1, true)
    if nil == close then
      err.fail('sekreto: not a valid http(s) address: ' .. addr.safeaddr(url))
    end
    host = authority:sub(2, close - 1)
    local after = authority:sub(close + 1)
    if ':' == after:sub(1, 1) then
      port = tonumber(after:sub(2)) or port
      explicit = true
    end
  else
    local colon = authority:match('.*()%:')
    if nil ~= colon then
      local maybe = tonumber(authority:sub(colon + 1))
      if nil ~= maybe then
        host = authority:sub(1, colon - 1)
        port = maybe
        explicit = true
      end
    end
  end

  -- A default port stays implicit in `Host:`. A SigV4 signature covers
  -- the host header, and `Host: x:443` is not what was signed.
  local hostheader = authority
  if explicit and (('https' == scheme and 443 == port) or
    ('http' == scheme and 80 == port))
  then
    hostheader = ('[' == authority:sub(1, 1)) and ('[' .. host .. ']') or host
  end

  return {
    scheme = scheme,
    host = host,
    port = port,
    hostheader = hostheader,
    target = target,
    tls = 'https' == scheme,
  }
end

local function lowerascii(text)
  return (text:gsub('[A-Z]', function(ch) return string.char(ch:byte() + 32) end))
end

--- One HTTP exchange. Returns {status, headers, body}, or nil plus the
--- reason it could not be made. A non-2xx status is RETURNED, not a
--- failure: a 404 from a vault means "no such secret".
---
--- `headers` is a list of {name, value} pairs, in order.
function M.request(method, url, headers, body)
  local target = M.split(url)

  local lines = {
    method .. ' ' .. target.target .. ' HTTP/1.1\r\n',
    'Host: ' .. target.hostheader .. '\r\n',
    'Accept: application/json\r\n',
    'Connection: close\r\n',
  }

  for _, pair in ipairs(headers or {}) do
    lines[#lines + 1] = pair[1] .. ': ' .. pair[2] .. '\r\n'
  end

  if nil ~= body then
    lines[#lines + 1] = 'Content-Length: ' .. #body .. '\r\n'
  end

  lines[#lines + 1] = '\r\n'
  if nil ~= body then
    lines[#lines + 1] = body
  end

  local raw, why = net.fetch(
    target.host, target.port, target.tls,
    table.concat(lines), M.TIMEOUT, M.MAXBODY
  )

  if nil == raw then
    return nil, why
  end

  local mark = raw:find('\r\n\r\n', 1, true)
  if nil == mark then
    return nil, 'the store answered with no headers'
  end

  local head = raw:sub(1, mark - 1)
  local rest = raw:sub(mark + 4)

  local first = head:match('^([^\r\n]*)')
  local status = tonumber(first:match('^%S+%s+(%d+)') or '')
  if nil == status then
    return nil, 'the store answered with no status'
  end

  local answerheaders = {}
  for line in head:gmatch('\r\n([^\r\n]+)') do
    local name, value = line:match('^([^:]+):%s*(.*)$')
    if nil ~= name then
      answerheaders[lowerascii(name)] = value
    end
  end

  local encoding = lowerascii(answerheaders['transfer-encoding'] or '')

  if nil ~= encoding:find('chunked', 1, true) then
    -- Bytes are sliced, never characters: a chunk boundary may fall
    -- inside a multibyte character, and a secret with any non-ASCII in it
    -- would otherwise be mangled.
    local parts = {}
    local at = 1

    while true do
      local stop = rest:find('\r\n', at, true)
      if nil == stop then
        break
      end

      local sizeline = rest:sub(at, stop - 1)
      local semi = sizeline:find(';', 1, true)
      if nil ~= semi then
        sizeline = sizeline:sub(1, semi - 1)
      end

      local size = tonumber(sizeline, 16)
      if nil == size then
        return nil, 'the store answered with a malformed chunk'
      end
      if 0 == size then
        break
      end

      parts[#parts + 1] = rest:sub(stop + 2, stop + 1 + size)
      at = stop + 2 + size + 2
    end

    rest = table.concat(parts)
  else
    local length = tonumber(answerheaders['content-length'] or '')
    if nil ~= length then
      rest = rest:sub(1, length)
    end
  end

  return { status = status, headers = answerheaders, body = rest, raw = #raw }
end

--- One JSON round-trip's result: the status, and the parsed body.
---
--- Network failure is always an error - an unreachable store is a store
--- that could not answer, and answering a miss there would fall silently
--- through to a weaker store.
function M.fetchjson(method, url, headers, body)
  local res, why = M.request(method, url, headers, body)

  if nil == res then
    err.fail('sekreto: cannot reach ' .. addr.bare(url) .. ': ' .. why)
  end

  -- One byte over the bound is enough to know it was exceeded. An endless
  -- body is a store that could not answer, so this raises rather than
  -- returning a miss - the latter would fall through to a weaker store on
  -- an attacker's cue.
  if M.MAXBODY < res.raw then
    err.fail('sekreto: oversized response from ' .. addr.bare(url))
  end

  local parsed = json.parse(res.body)

  -- A success status promised JSON; a body that does not parse means the
  -- store could not answer coherently. Error statuses may carry any body
  -- - they are decided on status alone.
  if 200 == res.status and nil == parsed then
    err.fail('sekreto: malformed response from ' .. addr.bare(url))
  end

  return { status = res.status, body = parsed }
end

return M
