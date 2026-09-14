-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lua/src/sekreto/plugins/hashicorp.lua)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- The hashicorp plugin: HashiCorp Vault, over HTTPS. Needs a socket, so
-- it is not a built-in kind - a chain that never names it never requires
-- this file (docs/design/plugin-providers.md).
--
-- A port of typescript/plugins/hashicorp.ts, which is canonical.

local err = require('feature.secrets.sekreto.err')
local name = require('feature.secrets.sekreto.name')
local addr = require('feature.secrets.sekreto.addr')
local providers = require('feature.secrets.sekreto.providers')
local json = require('feature.secrets.sekreto.plugins.json')
local httpjson = require('feature.secrets.sekreto.plugins.httpjson')
local support = require('feature.secrets.sekreto.plugins.support')

local fail = err.fail
local nonempty = providers.nonempty
local trimslash = providers.trimslash
local readfile = providers.readfile
local providerplugin = providers.providerplugin
local first = support.first
local nowms = support.nowms
local renewtime = support.renewtime
local NEVER = support.NEVER
local fetchjson = httpjson.fetchjson

local M = {}

--- HashiCorp Vault.
---
--- KV v2 (the default): `api.token` reads `{addr}/v1/{mount}/data/api`
--- and takes the `token` field of `data.data`. KV v1 reads
--- `{addr}/v1/{mount}/api` and takes the field of `data`. A 404 means
--- "not here" - a miss - so a vault can sit in a chain with fallbacks.
---
--- A Vault Enterprise namespace rides the X-Vault-Namespace header, on
--- logins as well as reads.
---
--- Instead of being handed a token, the provider can log in: Kubernetes
--- auth (the pod's service-account JWT, from its conventional path) or
--- AppRole. A failed login is an error, never a miss - it means this
--- store could not answer at all.
local function hashicorp(useaddr, token, mount, kv, vaultnamespace, auth)
  local address = useaddr or ''
  local usemount = nonempty(mount) and mount or 'secret'
  local usekv = kv or 2

  -- A version typo like kv: 3 must not quietly behave as v2 and turn its
  -- 404s into misses; there is nothing safe to assume it meant.
  if 1 ~= usekv and 2 ~= usekv then
    fail('sekreto: hashicorp: unsupported kv version: ' .. json.numstr(usekv))
  end

  local livetoken = nonempty(token) and token or nil
  local renewat = NEVER

  local function baseheaders()
    local out = {}
    if nonempty(vaultnamespace) then
      out[#out + 1] = { 'X-Vault-Namespace', vaultnamespace }
    end
    return out
  end

  local function login()
    if nil == auth then
      fail('sekreto: hashicorp: no token and no auth method')
    end

    local authmount = first(auth.mount, auth.method)
    local url = trimslash(address) .. '/v1/auth/' .. authmount .. '/login'
    local body

    if 'kubernetes' == auth.method then
      local jwt = auth.jwt

      if nil == jwt then
        local file = auth.jwtfile or
          '/var/run/secrets/kubernetes.io/serviceaccount/token'
        local text = readfile(file)
        if nil == text then
          fail('sekreto: hashicorp: cannot read jwt file ' .. file)
        end
        jwt = name.trim(text)
      end

      body = json.obj({ { 'role', auth.role or '' }, { 'jwt', jwt } })
    elseif 'approle' == auth.method then
      body = json.obj({
        { 'role_id', auth.roleid or '' },
        { 'secret_id', auth.secretid or '' },
      })
    else
      fail('sekreto: hashicorp: unknown auth method: ' .. tostring(auth.method))
    end

    local res = fetchjson('POST', url, baseheaders(), json.stringify(body))
    local got = json.text(json.dig(res.body, 'auth', 'client_token'))

    if 200 ~= res.status or nil == got or '' == got then
      fail('sekreto: hashicorp login failed: ' .. res.status .. ': ' .. url)
    end

    renewat = renewtime(json.dig(res.body, 'auth', 'lease_duration'))

    return got
  end

  return {
    lookup = function(secret)
      addr.checkaddr(address)

      if nil == livetoken or nowms() >= renewat then
        livetoken = login()
      end

      local ref = name.vaultref(secret)
      local base = trimslash(address) .. '/v1/' .. usemount
      local url = (1 == usekv) and (base .. '/' .. ref.path)
        or (base .. '/data/' .. ref.path)

      local headers = baseheaders()
      headers[#headers + 1] = { 'X-Vault-Token', livetoken or '' }

      local res = fetchjson('GET', url, headers)

      if 404 == res.status then
        return nil
      end

      if 200 ~= res.status then
        fail('sekreto: hashicorp error: ' .. res.status .. ': ' .. url)
      end

      local data = (1 == usekv) and json.dig(res.body, 'data')
        or json.dig(res.body, 'data', 'data')

      return json.text(json.dig(data, ref.field))
    end,
    describe = function()
      return 'hashicorp:' .. address .. '/' .. usemount
    end,
  }
end

--- The kind, as a voxgig/plugin definition.
M.hashicorp = providerplugin('hashicorp', function(spec)
  return hashicorp(spec.addr, spec.token, spec.mount, spec.kv,
    spec.vaultnamespace, spec.auth)
end)

return M
