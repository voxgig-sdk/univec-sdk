-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lua/src/sekreto/plugins/gcpsecrets.lua)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- The gcpsecrets plugin: GCP Secret Manager, over HTTPS, with the GCE
-- metadata server as a credential source.
--
-- A port of typescript/plugins/gcpsecrets.ts, which is canonical.

local err = require('feature.secrets.sekreto.err')
local name = require('feature.secrets.sekreto.name')
local addr = require('feature.secrets.sekreto.addr')
local providers = require('feature.secrets.sekreto.providers')
local json = require('feature.secrets.sekreto.plugins.json')
local httpjson = require('feature.secrets.sekreto.plugins.httpjson')
local support = require('feature.secrets.sekreto.plugins.support')
local crypto = require('feature.secrets.sekreto.plugins.crypto')

local fail = err.fail
local nonempty = providers.nonempty
local trimslash = providers.trimslash
local providerplugin = providers.providerplugin
local first = support.first
local nowms = support.nowms
local renewtime = support.renewtime
local NEVER = support.NEVER
local fetchjson = httpjson.fetchjson

local M = {}

--- GCP Secret Manager.
---
--- `api.token` reads secret `api_token` (dots flattened to `_`; Secret
--- Manager ids have no hierarchy and reject dots), latest version. The
--- token comes from config, then GOOGLE_OAUTH_ACCESS_TOKEN, then the
--- GCE/GKE metadata server - so on Google's own platform no credential
--- configuration is needed at all.
---
--- The metadata call itself is plain http to a link-local host by
--- platform design and carries no credential, so `checkaddr` guards the
--- Secret Manager address instead.
local function gcpsecrets(project, token, useaddr, metadataaddr)
  local livetoken = nil
  local renewat = NEVER

  local function usemetadataaddr()
    if nonempty(metadataaddr) then
      return metadataaddr
    end

    local host = os.getenv('GCE_METADATA_HOST')
    if nonempty(host) then
      return 'http://' .. host
    end

    return 'http://metadata.google.internal'
  end

  local function login()
    local configured = first(token, os.getenv('GOOGLE_OAUTH_ACCESS_TOKEN'))
    if '' ~= configured then
      return configured
    end

    local url = trimslash(usemetadataaddr()) ..
      '/computeMetadata/v1/instance/service-accounts/default/token'

    local res = fetchjson('GET', url, { { 'Metadata-Flavor', 'Google' } })
    local got = json.text(json.dig(res.body, 'access_token'))

    if 200 ~= res.status or nil == got or '' == got then
      fail('sekreto: gcp: no token and metadata server did not answer')
    end

    renewat = renewtime(json.dig(res.body, 'expires_in'))

    return got
  end

  return {
    lookup = function(secret)
      local useproject = project or ''
      if '' == useproject then
        fail('sekreto: gcp: no project')
      end

      local address = first(useaddr, 'https://secretmanager.googleapis.com')
      addr.checkaddr(address)

      if nil == livetoken or nowms() >= renewat then
        livetoken = login()
      end

      local url = trimslash(address) .. '/v1/projects/' .. useproject ..
        '/secrets/' .. name.flatname(secret, '_') .. '/versions/latest:access'

      local res = fetchjson('GET', url, { { 'authorization', 'Bearer ' .. livetoken } })

      if 404 == res.status then
        return nil
      end

      if 200 ~= res.status then
        fail('sekreto: gcp error: ' .. res.status .. ': ' .. url)
      end

      local data = json.asstr(json.dig(res.body, 'payload', 'data'))
      if nil == data then
        return nil
      end

      local decoded = crypto.unbase64(data)
      if nil == decoded then
        fail('sekreto: gcp: undecodable secret')
      end

      return decoded
    end,
    describe = function()
      return 'gcpsecrets:' .. (project or '')
    end,
  }
end

--- The kind, as a voxgig/plugin definition.
M.gcpsecrets = providerplugin('gcpsecrets', function(spec)
  return gcpsecrets(spec.project, spec.token, spec.addr, spec.metadataaddr)
end)

return M
