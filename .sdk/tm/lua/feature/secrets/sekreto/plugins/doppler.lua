-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lua/src/sekreto/plugins/doppler.lua)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- The doppler plugin: a whole Doppler config downloaded once, over
-- HTTPS, and answered from memory like a remote .env.
--
-- A port of typescript/plugins/doppler.ts, which is canonical.

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
local fetchjson = httpjson.fetchjson
local uriescape = support.uriescape

local M = {}

--- Doppler.
---
--- The whole config is downloaded once - Doppler's own bulk endpoint -
--- and answered from memory, like a remote .env: `api.token` is the
--- `API_TOKEN` entry. A failed load caches nothing, so it retries.
local function doppler(token, project, config, useaddr)
  local values = nil

  local function load()
    if nil ~= values then
      return values
    end

    local address = trimslash(first(useaddr, 'https://api.doppler.com'))
    addr.checkaddr(address)

    local url = address .. '/v3/configs/config/secrets/download?format=json'
    if nonempty(project) then
      url = url .. '&project=' .. uriescape(project)
    end
    if nonempty(config) then
      url = url .. '&config=' .. uriescape(config)
    end

    local res = fetchjson(
      'GET', url, { { 'authorization', 'Bearer ' .. (token or '') } }
    )

    local body = json.asobj(res.body)
    if 200 ~= res.status or nil == body then
      fail('sekreto: doppler error: ' .. res.status)
    end

    local loaded = {}
    for _, key in ipairs(body.keys) do
      local text = json.text(body.vals[key])
      if nil ~= text then
        loaded[key] = text
      end
    end

    values = loaded
    return loaded
  end

  return {
    -- The `prefix` option is deliberately not consulted by this kind.
    lookup = function(secret)
      return load()[name.envkey(secret)]
    end,
    describe = function()
      return 'doppler' ..
        (nonempty(project) and (':' .. project .. '/' .. (config or '')) or '')
    end,
  }
end

--- The kind, as a voxgig/plugin definition.
M.doppler = providerplugin('doppler', function(spec)
  return doppler(spec.token, spec.project, spec.config, spec.addr)
end)

return M
