-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lua/src/sekreto/plugins/infisical.lua)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- The infisical plugin: Infisical, over HTTPS, with a token or a
-- universal-auth machine identity.
--
-- A port of typescript/plugins/infisical.ts, which is canonical.

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
local providerplugin = providers.providerplugin
local first = support.first
local nowms = support.nowms
local renewtime = support.renewtime
local NEVER = support.NEVER
local fetchjson = httpjson.fetchjson
local uriescape = support.uriescape

local M = {}

--- Infisical.
---
--- `api.token` reads the secret keyed `API_TOKEN` at a secret path in one
--- environment of a project. Auth is a token, or a universal-auth
--- (machine identity) login with clientid/clientsecret.
local function infisical(useaddr, token, clientid, clientsecret, project, environment, path)
  local livetoken = nil
  local renewat = NEVER

  local function login(address)
    if nonempty(token) then
      return token
    end

    if not nonempty(clientid) or not nonempty(clientsecret) then
      fail('sekreto: infisical: no token and no client credentials')
    end

    local body = json.obj({
      { 'clientId', clientid },
      { 'clientSecret', clientsecret },
    })

    local res = fetchjson(
      'POST', address .. '/api/v1/auth/universal-auth/login',
      { { 'content-type', 'application/json' } }, json.stringify(body)
    )

    local got = json.text(json.dig(res.body, 'accessToken'))
    if 200 ~= res.status or nil == got or '' == got then
      fail('sekreto: infisical login failed: ' .. res.status)
    end

    -- camelCase, unlike everyone else's expires_in.
    renewat = renewtime(json.dig(res.body, 'expiresIn'))

    return got
  end

  return {
    lookup = function(secret)
      local address = trimslash(first(useaddr, 'https://app.infisical.com'))
      addr.checkaddr(address)

      local useproject = project or ''
      local useenvironment = environment or ''
      if '' == useproject or '' == useenvironment then
        fail('sekreto: infisical: no project/environment')
      end

      if nil == livetoken or nowms() >= renewat then
        livetoken = login(address)
      end

      local url = address .. '/api/v3/secrets/raw/' .. name.envkey(secret) ..
        '?workspaceId=' .. uriescape(useproject) ..
        '&environment=' .. uriescape(useenvironment) ..
        '&secretPath=' .. uriescape(first(path, '/'))

      local res = fetchjson('GET', url, { { 'authorization', 'Bearer ' .. livetoken } })

      if 404 == res.status then
        return nil
      end

      if 200 ~= res.status then
        fail('sekreto: infisical error: ' .. res.status)
      end

      return json.text(json.dig(res.body, 'secret', 'secretValue'))
    end,
    describe = function()
      return 'infisical:' .. (project or '') .. '/' .. (environment or '')
    end,
  }
end

--- The kind, as a voxgig/plugin definition.
M.infisical = providerplugin('infisical', function(spec)
  return infisical(spec.addr, spec.token, spec.clientid, spec.clientsecret,
    spec.project, spec.environment, spec.path)
end)

return M
