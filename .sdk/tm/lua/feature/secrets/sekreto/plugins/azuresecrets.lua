-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lua/src/sekreto/plugins/azuresecrets.lua)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- The azuresecrets plugin: Azure Key Vault, over HTTPS, with a
-- client-credentials login and the IMDS managed-identity endpoint.
--
-- A port of typescript/plugins/azuresecrets.ts, which is canonical.

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

local AZURERESOURCE = 'https://vault.azure.net'

--- Azure Key Vault.
---
--- `api.token` reads secret `api-token` (dots flattened to `-`; Key Vault
--- names allow nothing else), current version. The token comes from
--- config, then a client-credentials login when tenant/clientid/
--- clientsecret are given, then the IMDS managed-identity endpoint.
local function azuresecrets(vault, token, tenant, clientid, clientsecret,
  loginaddr, imdsaddr, apiversion)
  local livetoken = nil
  local renewat = NEVER

  local function login()
    if nonempty(token) then
      return token
    end

    if nonempty(tenant) and nonempty(clientid) and nonempty(clientsecret) then
      local useloginaddr = first(loginaddr, 'https://login.microsoftonline.com')
      addr.checkaddr(useloginaddr)

      local url = trimslash(useloginaddr) .. '/' .. tenant .. '/oauth2/v2.0/token'
      local form = 'grant_type=client_credentials&client_id=' ..
        uriescape(clientid) ..
        '&client_secret=' .. uriescape(clientsecret) ..
        '&scope=' .. uriescape(AZURERESOURCE .. '/.default')

      local res = fetchjson(
        'POST', url,
        { { 'content-type', 'application/x-www-form-urlencoded' } },
        form
      )

      local got = json.text(json.dig(res.body, 'access_token'))
      if 200 ~= res.status or nil == got or '' == got then
        fail('sekreto: azure login failed: ' .. res.status)
      end

      renewat = renewtime(json.dig(res.body, 'expires_in'))
      return got
    end

    local imds = trimslash(first(imdsaddr, 'http://169.254.169.254')) ..
      '/metadata/identity/oauth2/token?api-version=2018-02-01&resource=' ..
      uriescape(AZURERESOURCE)

    local res = fetchjson('GET', imds, { { 'Metadata', 'true' } })

    local got = json.text(json.dig(res.body, 'access_token'))
    if 200 ~= res.status or nil == got or '' == got then
      fail('sekreto: azure: no token, no client credentials, and IMDS did not answer')
    end

    -- IMDS sends expires_in as a STRING, unlike everyone else.
    renewat = renewtime(json.dig(res.body, 'expires_in'))
    return got
  end

  return {
    lookup = function(secret)
      local usevault = vault or ''
      if '' == usevault then
        fail('sekreto: azure: no vault')
      end

      -- Only an explicit scheme is a URL; a vault NAMED httpvault must
      -- still become https://httpvault.vault.azure.net.
      local vaulturl
      if 'http://' == usevault:sub(1, 7) or 'https://' == usevault:sub(1, 8) then
        vaulturl = usevault
      else
        vaulturl = 'https://' .. usevault .. '.vault.azure.net'
      end
      addr.checkaddr(vaulturl)

      if nil == livetoken or nowms() >= renewat then
        livetoken = login()
      end

      local url = trimslash(vaulturl) .. '/secrets/' .. name.flatname(secret, '-') ..
        '?api-version=' .. first(apiversion, '7.4')

      local res = fetchjson('GET', url, { { 'authorization', 'Bearer ' .. livetoken } })

      if 404 == res.status then
        return nil
      end

      if 200 ~= res.status then
        fail('sekreto: azure error: ' .. res.status .. ': ' .. addr.bare(url))
      end

      return json.text(json.dig(res.body, 'value'))
    end,
    describe = function()
      return 'azuresecrets:' .. (vault or '')
    end,
  }
end

--- The kind, as a voxgig/plugin definition.
M.azuresecrets = providerplugin('azuresecrets', function(spec)
  return azuresecrets(spec.vault, spec.token, spec.tenant, spec.clientid,
    spec.clientsecret, spec.loginaddr, spec.imdsaddr, spec.apiversion)
end)

return M
