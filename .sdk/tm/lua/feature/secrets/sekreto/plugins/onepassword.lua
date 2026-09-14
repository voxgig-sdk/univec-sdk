-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lua/src/sekreto/plugins/onepassword.lua)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- The onepassword plugin: 1Password through a Connect server, over
-- HTTPS.
--
-- A port of typescript/plugins/onepassword.ts, which is canonical.

local err = require('feature.secrets.sekreto.err')
local name = require('feature.secrets.sekreto.name')
local addr = require('feature.secrets.sekreto.addr')
local providers = require('feature.secrets.sekreto.providers')
local json = require('feature.secrets.sekreto.plugins.json')
local httpjson = require('feature.secrets.sekreto.plugins.httpjson')
local support = require('feature.secrets.sekreto.plugins.support')

local fail = err.fail
local trimslash = providers.trimslash
local providerplugin = providers.providerplugin
local fetchjson = httpjson.fetchjson
local uriescape = support.uriescape

local M = {}

--- 1Password, through a Connect server.
---
--- The item titled `api.token` (titles keep their dots), in the named
--- vault. The value is the field with purpose PASSWORD, or the field
--- labelled `value`. A vault that cannot be found is an error - config
--- names it, so its absence is a broken store, not a missing secret.
local function onepassword(useaddr, token, vault)
  local vaultid = nil

  local function auth()
    return { { 'authorization', 'Bearer ' .. (token or '') } }
  end

  local function resolvevault(address)
    local want = vault or ''
    if '' == want then
      fail('sekreto: onepassword: no vault')
    end

    local res = fetchjson('GET', address .. '/v1/vaults', auth())
    local list = json.asarr(res.body)

    if 200 ~= res.status or nil == list then
      fail('sekreto: onepassword error: ' .. res.status .. ': listing vaults')
    end

    for _, entry in ipairs(list) do
      local id = json.text(json.dig(entry, 'id'))
      if want == id or want == json.text(json.dig(entry, 'name')) then
        return id or ''
      end
    end

    fail('sekreto: onepassword: no vault named ' .. want)
  end

  return {
    lookup = function(secret)
      name.checkname(secret)

      local address = trimslash(useaddr or '')
      if '' == address then
        fail('sekreto: onepassword: no addr')
      end
      addr.checkaddr(address)

      if nil == vaultid then
        vaultid = resolvevault(address)
      end

      local filter = uriescape('title eq "' .. secret .. '"')
      local found = fetchjson(
        'GET', address .. '/v1/vaults/' .. vaultid .. '/items?filter=' .. filter, auth()
      )

      local items = json.asarr(found.body)
      if 200 ~= found.status or nil == items then
        fail('sekreto: onepassword error: ' .. found.status .. ': finding ' .. secret)
      end

      if 0 == #items then
        return nil
      end

      local item = fetchjson(
        'GET',
        address .. '/v1/vaults/' .. vaultid .. '/items/' ..
          (json.text(json.dig(items[1], 'id')) or ''),
        auth()
      )

      if 200 ~= item.status then
        fail('sekreto: onepassword error: ' .. item.status .. ': reading ' .. secret)
      end

      local fields = json.asarr(json.dig(item.body, 'fields')) or {}

      for _, entry in ipairs(fields) do
        if 'PASSWORD' == json.asstr(json.dig(entry, 'purpose')) then
          return json.text(json.dig(entry, 'value'))
        end
      end
      for _, entry in ipairs(fields) do
        if 'value' == json.asstr(json.dig(entry, 'label')) then
          return json.text(json.dig(entry, 'value'))
        end
      end

      return nil
    end,
    describe = function()
      return 'onepassword:' .. (vault or '')
    end,
  }
end

--- The kind, as a voxgig/plugin definition.
M.onepassword = providerplugin('onepassword', function(spec)
  return onepassword(spec.addr, spec.token, spec.vault)
end)

return M
