-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lua/src/sekreto/plugins/sigv4.lua)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- AWS Signature Version 4, hand-rolled.
--
-- The AWS providers need exactly one thing from the AWS SDK - request
-- signing - and taking the SDK for it would break the no-dependency rule
-- that keeps every port honest. SigV4 is a stable, published algorithm
-- built from HMAC-SHA256, which src/sekreto/plugins/crypto.lua carries.
-- It moved out of the core with the aws plugin: the core of no port
-- imports a hash function (docs/design/plugin-providers.md).
--
-- `sigv4` is pure: the caller passes the timestamp, so the same input
-- yields the same signature everywhere. That is what lets the shared spec
-- carry known-answer cases that all ports must reproduce bit for bit, and
-- lets the integration mock recompute the signature server-side.
--
-- `uriescape` and `uridecode` live in support, because four plugins that
-- sign nothing need them and reaching them through here would put
-- SHA-256 and HMAC behind all four.
--
-- A port of typescript/plugins/sigv4.ts, which is canonical.

local crypto = require('feature.secrets.sekreto.plugins.crypto')
local support = require('feature.secrets.sekreto.plugins.support')

local M = {}

local uriescape = support.uriescape
local uridecode = support.uridecode

-- ASCII case folding, spelled out. `string.upper` and `string.lower` go
-- through the C library's toupper/tolower, which follow the machine's
-- locale - and in a Turkish locale `i` does not fold to `I`.
local function lowerascii(text)
  return (text:gsub('[A-Z]', function(ch) return string.char(ch:byte() + 32) end))
end

local function upperascii(text)
  return (text:gsub('[a-z]', function(ch) return string.char(ch:byte() - 32) end))
end

--- The canonical query string: each pair RFC 3986-escaped, sorted by
--- escaped key then escaped value. `?b=2&a=1` signs as `a=1&b=2`.
function M.canonicalquery(query)
  if '' == query then
    return ''
  end

  local pairlist = {}
  local at = 1

  while true do
    local stop = query:find('&', at, true)
    local piece = stop and query:sub(at, stop - 1) or query:sub(at)

    local eq = piece:find('=', 1, true)
    local key = eq and piece:sub(1, eq - 1) or piece
    local value = eq and piece:sub(eq + 1) or ''

    pairlist[#pairlist + 1] = {
      uriescape(uridecode(key)),
      uriescape(uridecode(value)),
    }

    if not stop then
      break
    end
    at = stop + 1
  end

  table.sort(pairlist, function(left, right)
    if left[1] ~= right[1] then
      return left[1] < right[1]
    end
    return left[2] < right[2]
  end)

  local parts = {}
  for index, pair in ipairs(pairlist) do
    parts[index] = pair[1] .. '=' .. pair[2]
  end

  return table.concat(parts, '&')
end

--- Split a URL the way the WHATWG `host` property does, by hand.
---
--- No platform URL type is trusted here: the signature covers `host`, and
--- a parser that keeps an explicitly written `:443`, or that leaves
--- userinfo in, signs something the server will not agree with.
local function spliturl(url)
  local mark = url:find('://', 1, true)
  local scheme = mark and lowerascii(url:sub(1, mark - 1)) or ''
  local rest = mark and url:sub(mark + 3) or url

  local stop = rest:find('[/?#]')
  local authority = stop and rest:sub(1, stop - 1) or rest
  local tail = stop and rest:sub(stop) or ''

  -- Userinfo is stripped: it is never part of the signed host.
  local at = authority:find('@[^@]*$')
  if at then
    authority = authority:sub(at + 1)
  end

  local host = authority
  local port = ''

  if '[' == host:sub(1, 1) then
    local close = host:find(']', 1, true)
    if close then
      local after = host:sub(close + 1)
      host = host:sub(1, close)
      if ':' == after:sub(1, 1) then
        port = after:sub(2)
      end
    end
  else
    local colon = host:find(':', 1, true)
    if colon then
      port = host:sub(colon + 1)
      host = host:sub(1, colon - 1)
    end
  end

  host = lowerascii(host)

  -- A default port is not written: `Host: x:443` is not what was signed.
  if ('https' == scheme and '443' == port) or ('http' == scheme and '80' == port) then
    port = ''
  end

  local path = tail
  local query = ''

  local mark2 = tail:find('?', 1, true)
  if mark2 then
    path = tail:sub(1, mark2 - 1)
    query = tail:sub(mark2 + 1)
    local hash = query:find('#', 1, true)
    if hash then
      query = query:sub(1, hash - 1)
    end
  else
    local hash = tail:find('#', 1, true)
    if hash then
      path = tail:sub(1, hash - 1)
    end
  end

  if '' == path then
    path = '/'
  end

  return {
    scheme = scheme,
    host = host,
    port = port,
    hostheader = ('' == port) and host or (host .. ':' .. port),
    path = path,
    query = query,
  }
end

M.spliturl = spliturl

--- Trim, then collapse every internal run of spaces and tabs to one
--- space: AWS folds sequential whitespace before signing, so a header
--- value `a  b\tc` must sign as `a b c`.
local function foldvalue(text)
  local trimmed = text:gsub('^[ \t\r\n]+', ''):gsub('[ \t\r\n]+$', '')
  return (trimmed:gsub('[ \t\r\n]+', ' '))
end

--- Sign one request.
---
--- `input` is a table whose field names are the spec's JSON keys verbatim:
--- method, url, service, region, keyid, secret, datetime, headers, body,
--- session.
---
--- Returns an ORDERED list of {name, value} pairs: authorization,
--- x-amz-date, and x-amz-security-token only when a session was given.
--- The order is contract - callers print it field by field.
function M.sigv4(input)
  local url = spliturl(input.url or '')

  local datetime = input.datetime or ''
  local date = datetime:sub(1, 8)
  local session = input.session
  if nil ~= session and '' == session then
    session = nil
  end

  -- The caller's headers first, then host / x-amz-date / the session
  -- token AFTER them, so those always win.
  local headers = {}
  local names = {}

  local function put(name, value)
    if nil == headers[name] then
      names[#names + 1] = name
    end
    headers[name] = value
  end

  for _, pair in ipairs(input.headers or {}) do
    put(lowerascii(pair[1]), foldvalue(pair[2]))
  end

  put('host', url.hostheader)
  put('x-amz-date', datetime)
  if nil ~= session then
    put('x-amz-security-token', session)
  end

  table.sort(names)

  local canonparts = {}
  for index, name in ipairs(names) do
    canonparts[index] = name .. ':' .. headers[name] .. '\n'
  end

  local canonicalheaders = table.concat(canonparts)
  local signedheaders = table.concat(names, ';')

  local canonicalrequest = table.concat({
    upperascii(input.method or ''),
    url.path,
    M.canonicalquery(url.query),
    canonicalheaders,
    signedheaders,
    crypto.sha256hex(input.body or ''),
  }, '\n')

  local scope = date .. '/' .. (input.region or '') .. '/' ..
    (input.service or '') .. '/aws4_request'

  local stringtosign = table.concat({
    'AWS4-HMAC-SHA256',
    datetime,
    scope,
    crypto.sha256hex(canonicalrequest),
  }, '\n')

  local kdate = crypto.hmac('AWS4' .. (input.secret or ''), date)
  local kregion = crypto.hmac(kdate, input.region or '')
  local kservice = crypto.hmac(kregion, input.service or '')
  local ksigning = crypto.hmac(kservice, 'aws4_request')
  local signature = crypto.hex(crypto.hmac(ksigning, stringtosign))

  local out = {
    {
      'authorization',
      'AWS4-HMAC-SHA256 Credential=' .. (input.keyid or '') .. '/' .. scope ..
        ', SignedHeaders=' .. signedheaders ..
        ', Signature=' .. signature,
    },
    { 'x-amz-date', datetime },
  }

  if nil ~= session then
    out[#out + 1] = { 'x-amz-security-token', session }
  end

  return out
end

return M
