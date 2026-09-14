-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lua/src/sekreto/plugins/net.lua)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- The bridge to the transport helper - a PLUGIN module, never the core.
--
-- Everything that opens a socket or starts a child process goes through
-- this file, so a chain of built-in kinds never requires it and never
-- needs native/sekretonet.c to have been built at all.
--
-- Lua cannot open a socket, and `io.popen` is unidirectional - so a
-- request cannot be written to a child and its answer read back through
-- the same handle. The request is therefore handed over in a file and the
-- answer comes back on the child's stdout.
--
-- The file, not the command line, because a vault token rides in the
-- request headers and the process table is world readable. It is created
-- by `os.tmpname`, which uses `mkstemp` and so is already 0600, and
-- native/sekretonet.c unlinks it before reading a byte of it.
--
-- Nothing about HTTP is known here. This module moves bytes, exactly as
-- the helper does - and it runs children, which is the other half of what
-- the helper is for.

local err = require('feature.secrets.sekreto.err')
local name = require('feature.secrets.sekreto.name')

local M = {}

--- Where the helper binary is, worked out from this file's own path
--- rather than from the working directory: test/checks.sh runs the CLI
--- from an EMPTY directory with the environment wiped, so nothing in the
--- process's surroundings can be relied on to find it.
local function helperpath()
  local source = debug.getinfo(1, 'S').source

  if '@' == source:sub(1, 1) then
    local dir = source:sub(2):match('^(.*)/feature/secrets/sekreto/plugins/net%.lua$')
    if nil ~= dir then
      return dir .. '/feature/secrets/native/sekreto-net'
    end
  end

  return 'feature/secrets/native/sekreto-net'
end

M.HELPER = helperpath()

--- A shell-safe single-quoted word. `io.popen` goes through `/bin/sh`,
--- and the only two words this module ever passes it are paths it made
--- itself - but a path is checked rather than assumed.
local function quotepath(path)
  if nil ~= path:find("'", 1, true) or nil ~= path:find('\n', 1, true) then
    err.fail('sekreto: transport helper path is not usable: ' .. path)
  end
  return "'" .. path .. "'"
end

--- One length-prefixed field.
local function field(name, value)
  return name .. ' ' .. #value .. '\n' .. value .. '\n'
end

--- Run the helper over one request. Returns the answer verb and payload.
local function call(fields)
  local path = os.tmpname()

  local handle = io.open(path, 'wb')
  if nil == handle then
    os.remove(path)
    err.fail('sekreto: cannot write a transport request')
  end

  handle:write(table.concat(fields))
  handle:close()

  local pipe = io.popen(quotepath(M.HELPER) .. ' ' .. quotepath(path) .. ' 2>/dev/null', 'r')
  if nil == pipe then
    os.remove(path)
    return 'ERR', 'cannot start the transport helper'
  end

  local answer = pipe:read('a') or ''
  pipe:close()

  -- The helper unlinks it; this is the backstop for the case where the
  -- helper never ran at all.
  os.remove(path)

  local stop = answer:find('\n', 1, true)
  if nil == stop then
    return 'ERR',
      'the transport helper did not answer (is ' .. M.HELPER .. ' built?)'
  end

  local head = answer:sub(1, stop - 1)
  local rest = answer:sub(stop + 1)

  local verb = head:match('^(%u+)')

  if 'ERR' == verb then
    return 'ERR', rest
  end

  if 'OK' == verb then
    return 'OK', rest
  end

  if 'EXEC' == verb then
    local code, outlen, errlen = head:match('^EXEC (%-?%d+) (%d+) (%d+)$')
    if nil == code then
      return 'ERR', 'the transport helper answered incoherently'
    end
    outlen = tonumber(outlen)
    errlen = tonumber(errlen)
    return 'EXEC', {
      status = tonumber(code),
      out = rest:sub(1, outlen),
      why = rest:sub(outlen + 1, outlen + errlen),
    }
  end

  return 'ERR', 'the transport helper answered incoherently'
end

--- Connect, send `payload`, read the answer to end of stream.
---
--- Returns the response bytes, or nil plus a reason. A reason is always a
--- failure - never a miss.
function M.fetch(host, port, usetls, payload, timeoutms, maxbody)
  local verb, got = call({
    field('mode', 'fetch'),
    field('host', host),
    field('port', tostring(port)),
    field('tls', usetls and '1' or '0'),
    field('timeout', tostring(timeoutms)),
    field('maxbody', tostring(maxbody)),
    field('data', payload),
  })

  if 'OK' ~= verb then
    return nil, ('table' == type(got)) and 'transport failure' or got
  end

  return got
end

--- Run a child to completion and collect both its streams separately.
---
--- `argv` is an array and never a shell string. `overrides` is a list of
--- `NAME=value` entries applied ON TOP of the inherited environment: Lua
--- cannot enumerate its own environment (`os.getenv` reads one name), so
--- building a complete one here would silently drop every variable this
--- port did not think to name, and boru reads several of its own.
---
--- Returns {status, out, why}, or nil plus a reason when the child could
--- not be started at all.
function M.exec(argv, overrides)
  local fields = { field('mode', 'exec') }

  for _, arg in ipairs(argv) do
    fields[#fields + 1] = field('arg', arg)
  end
  for _, entry in ipairs(overrides or {}) do
    fields[#fields + 1] = field('setenv', entry)
  end

  local verb, got = call(fields)

  if 'EXEC' ~= verb then
    -- The helper reports a failed exec through a close-on-exec status
    -- pipe, so "could not be started" is never guessed from an exit code
    -- a real child is equally free to produce. It becomes
    -- `sekreto: cannot run <command>: <err>`, which is a failure and
    -- never a miss.
    local reason = ('table' == type(got)) and 'transport failure' or got
    return nil, (reason:match('^EXECFAIL (.*)$') or reason)
  end

  return got
end

--- What a finished child process left behind, with a failure to start it
--- raised rather than returned.
---
--- Both streams are drained concurrently and stdin is closed; see
--- native/sekretonet.c, which does the draining. Argv is an array and
--- never a shell string, and no secret is ever put on a command line.
function M.runcmd(argv, overrides, command)
  local ran, why = M.exec(argv, overrides)

  if nil == ran then
    err.fail('sekreto: cannot run ' .. command .. ': ' .. why)
  end

  return ran.out, name.trim(ran.why), ran.status
end

return M
