-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lua/src/sekreto/plugins/boru.lua)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- The boru plugin: a boru vault, through its own CLI or its own wire
-- protocol. Needs a child process, and HTTPS for the wire path.
--
-- A port of typescript/plugins/boru.ts, which is canonical.

local err = require('feature.secrets.sekreto.err')
local name = require('feature.secrets.sekreto.name')
local addr = require('feature.secrets.sekreto.addr')
local providers = require('feature.secrets.sekreto.providers')
local json = require('feature.secrets.sekreto.plugins.json')
local httpjson = require('feature.secrets.sekreto.plugins.httpjson')
local support = require('feature.secrets.sekreto.plugins.support')
local net = require('feature.secrets.sekreto.plugins.net')

local fail = err.fail
local nonempty = providers.nonempty
local trimslash = providers.trimslash
local providerplugin = providers.providerplugin
local stripnewline = support.stripnewline
local fetchjson = httpjson.fetchjson
local runcmd = net.runcmd

local M = {}

--- Does this boru failure mean "no such secret" rather than "I could not
--- answer"? Matched on boru's own wording for a missing alias.
function M.borumiss(why)
  return nil ~= why:find('no alias named', 1, true)
end

--- A boru vault (https://github.com/boru-lang/boru).
---
--- Two ways in, both boru's own. With no `addr`, the CLI:
--- `boru vault get --reveal <alias>` prints the secret on stdout and
--- nothing else. The passphrase is read by boru itself from
--- BORU_VAULT_PASSPHRASE; sekreto never accepts it as config and never
--- puts it on a command line, where the process table would publish it.
---
--- With an `addr`, boru's wire protocol: a read-only, HashiCorp-shaped
--- provision API. A sekreto name is already a valid boru alias, and boru
--- aliases keep their dots, so `api.token` is the single path segment
--- `api.token` - not the `api`/`token` split a HashiCorp KV gets.
local function boru(command, namespace, home, useaddr, token, mount)
  local usecommand = nonempty(command) and command or 'boru'
  local address = (nil == useaddr) and '' or trimslash(useaddr)
  local usetoken = token or ''
  local usemount = nonempty(mount) and mount or 'secret'

  local function wirelookup(secret)
    addr.checkaddr(address)

    local alias = nonempty(namespace) and (namespace .. '/' .. secret) or secret
    local url = address .. '/v1/' .. usemount .. '/data/' .. alias

    local res = fetchjson('GET', url, { { 'X-Vault-Token', usetoken } })

    if 404 == res.status then
      return nil
    end

    if 200 ~= res.status then
      fail('sekreto: boru serve error: ' .. res.status .. ': ' .. url)
    end

    return json.text(json.dig(res.body, 'data', 'data', 'value'))
  end

  return {
    lookup = function(secret)
      name.checkname(secret)

      if '' ~= address then
        return wirelookup(secret)
      end

      local alias = nonempty(namespace) and (namespace .. ':' .. secret) or secret

      -- BORU_HOME is the only variable sekreto sets for the child; the
      -- passphrase is boru's own to read from BORU_VAULT_PASSPHRASE, and
      -- is never config here and never on a command line.
      local overrides = nil
      if nonempty(home) then
        overrides = { 'BORU_HOME=' .. home }
      end

      local out, why, status = runcmd(
        { usecommand, 'vault', 'get', '--reveal', alias }, overrides, usecommand
      )

      if 0 == status then
        -- boru prints the value and one newline, and nothing else.
        return stripnewline(out)
      end

      -- "no alias named" is boru saying it does not hold this secret,
      -- which is a miss. A locked vault or a wrong passphrase is not -
      -- treating it as one would fall through to a weaker store without
      -- saying so.
      if M.borumiss(why) then
        return nil
      end

      fail('sekreto: boru vault error: ' ..
        (('' == why) and ('exit ' .. status) or why))
    end,
    describe = function()
      if '' ~= address then
        return 'boru:' .. address
      end
      return 'boru' .. (nonempty(namespace) and (':' .. namespace) or '')
    end,
  }
end

--- The kind, as a voxgig/plugin definition.
M.boru = providerplugin('boru', function(spec)
  return boru(spec.command, spec.namespace, spec.home, spec.addr,
    spec.token, spec.mount)
end)

return M
