-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lua/src/sekreto/plugins/secretspec.lua)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- The secretspec plugin: SecretSpec, through its CLI. Needs a child
-- process, so it is not a built-in kind.
--
-- A port of typescript/plugins/secretspec.ts, which is canonical.

local err = require('feature.secrets.sekreto.err')
local name = require('feature.secrets.sekreto.name')
local providers = require('feature.secrets.sekreto.providers')
local support = require('feature.secrets.sekreto.plugins.support')
local net = require('feature.secrets.sekreto.plugins.net')

local fail = err.fail
local nonempty = providers.nonempty
local providerplugin = providers.providerplugin
local first = support.first
local stripnewline = support.stripnewline
local runcmd = net.runcmd

local M = {}

--- Does this SecretSpec failure mean "no such secret" rather than "I
--- could not answer"?
---
--- MATCHED ON THE WHOLE PHRASE, NOT ON "not found". SecretSpec also says
--- `Provider backend 'keyring' not found`, which is a store that could
--- not answer at all - and reading that as a miss is the worst failure
--- this library has, because the chain then falls through to a weaker
--- store without saying so. The key is required to appear, so the two
--- cannot be confused.
function M.secretspecmiss(why, key)
  return nil ~= why:find("Secret '" .. key .. "' not found", 1, true)
end

--- SecretSpec (https://secretspec.dev), read through its CLI.
---
--- `backend` selects one of SecretSpec's own backends (`--provider`) and
--- is called `backend` here only because `provider` already means a
--- sekreto provider. A reason is required, not optional: SecretSpec
--- records every read in an audit log and refuses to read without one.
local function secretspec(command, file, profile, backend, reason, prefix)
  local usecommand = nonempty(command) and command or 'secretspec'

  return {
    lookup = function(secret)
      local key = name.envkey(secret, prefix)

      local argv = { usecommand }
      if nonempty(file) then
        argv[#argv + 1] = '--file'
        argv[#argv + 1] = file
      end
      argv[#argv + 1] = 'get'
      argv[#argv + 1] = key
      if nonempty(backend) then
        argv[#argv + 1] = '--provider'
        argv[#argv + 1] = backend
      end
      if nonempty(profile) then
        argv[#argv + 1] = '--profile'
        argv[#argv + 1] = profile
      end
      argv[#argv + 1] = '--reason'
      argv[#argv + 1] = first(reason, 'sekreto')

      local out, why, status = runcmd(argv, nil, usecommand)

      if 0 == status then
        return stripnewline(out)
      end

      if M.secretspecmiss(why, key) then
        return nil
      end

      fail('sekreto: secretspec error: ' ..
        (('' == why) and ('exit ' .. status) or why))
    end,
    describe = function()
      return 'secretspec' .. (nonempty(backend) and (':' .. backend) or '')
    end,
  }
end

--- The kind, as a voxgig/plugin definition.
M.secretspec = providerplugin('secretspec', function(spec)
  return secretspec(spec.command, spec.file, spec.profile, spec.backend,
    spec.reason, spec.prefix)
end)

return M
