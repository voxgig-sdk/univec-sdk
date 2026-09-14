-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lua/src/sekreto/providers.lua)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- What a provider is, how a provider kind becomes a voxgig/plugin
-- definition - and the four BUILT-IN kinds.
--
-- A provider answers one question: "do you have this secret?" It returns
-- the value, or nil to mean "ask the next one". Nothing else about a
-- provider is visible to the caller - which is the point: an app reads
-- `api.token` and never learns whether it came from the environment, a
-- .env file, HashiCorp Vault or a boru vault.
--
-- Two failure shapes, and they are never interchangeable. A store that
-- does not hold the secret is a MISS (nil) - the chain carries on. A
-- store that could not answer - bad credentials, unreachable host,
-- missing configuration - is an ERROR: falling through there would
-- quietly reach for a weaker store.
--
-- A provider is a plain table with two functions, `lookup` and
-- `describe`, and no lifecycle. It is duck-typed: anything with a
-- callable `lookup` is a provider, whatever built it.
--
-- THIS MODULE REQUIRES NO SOCKET, NO DIGEST AND NO CHILD PROCESS. What
-- makes a kind built in is that it needs nothing of the platform beyond
-- reading a local file; every kind that opens a socket, signs a request
-- or spawns a process is a plugin under plugins/, its own module,
-- required only by a program that names it. `sekreto.plugins.net` - and
-- with it native/sekretonet.c, this port's only compiled artifact - is
-- reached by no file the core requires (docs/design/plugin-providers.md).
--
-- A port of typescript/src/provider/support.ts and
-- typescript/src/provider/builtin.ts, which are canonical.

local plugin = require('feature.secrets.plugin')

local err = require('feature.secrets.sekreto.err')
local name = require('feature.secrets.sekreto.name')

local fail = err.fail

local M = {}

-- ------------------------------------------------------------ the specs

--- What a credential field reports about itself.
local function setornot(value)
  if nil == value or '' == value then
    return '[unset]'
  end
  return '[set]'
end

--- Printed without its credentials.
---
--- Lua's `tostring` on a bare table prints an address, but anything that
--- walks a spec - a config dumper, a logging helper - would otherwise
--- reach the Vault token, the AWS secret access key and the Azure client
--- secret. Fields holding a credential report whether they are set, never
--- what they are.
local SPECMT = {
  __tostring = function(spec)
    return 'ProviderSpec(kind=' .. tostring(spec.kind) ..
      ', name=' .. tostring(spec.name) ..
      ', addr=' .. tostring(spec.addr) ..
      ', token=' .. setornot(spec.token) ..
      ', secret=' .. setornot(spec.secret) ..
      ', clientsecret=' .. setornot(spec.clientsecret) ..
      ', auth=' .. tostring(spec.auth) .. ')'
  end,
  __name = 'ProviderSpec',
}

local AUTHMT = {
  __tostring = function(auth)
    return 'AuthSpec(method=' .. tostring(auth.method) ..
      ', mount=' .. tostring(auth.mount) ..
      ', role=' .. tostring(auth.role) ..
      ', jwtfile=' .. tostring(auth.jwtfile) ..
      ', roleid=' .. tostring(auth.roleid) ..
      ', jwt=' .. setornot(auth.jwt) ..
      ', secretid=' .. setornot(auth.secretid) .. ')'
  end,
  __name = 'AuthSpec',
}

--- The declarative form of a provider, as used in config and in the
--- shared spec. `kind` picks the provider; everything else is that
--- kind's own.
function M.spec(fields)
  return setmetatable(fields or {}, SPECMT)
end

--- Logging in to a vault instead of being handed a token. `method` is
--- `kubernetes` or `approle`; `mount` defaults to the method name.
function M.authspec(fields)
  return setmetatable(fields or {}, AUTHMT)
end

-- -------------------------------------------------------------- helpers

local function trimslash(text)
  if '/' == text:sub(-1) then
    return text:sub(1, #text - 1)
  end
  return text
end

M.trimslash = trimslash

local function nonempty(value)
  return nil ~= value and '' ~= value
end

M.nonempty = nonempty

--- The whole of a file, or nil plus the reason.
---
--- Absence - of the file OR of a directory on the way to it - is "no
--- secrets here" and answers nil with no reason, so the caller can tell
--- it from a permission error, which is a store that could not answer.
--- The reason string is not consulted; it comes from the C library's
--- strerror and follows the machine's locale.
local function readfile(path)
  local handle, why, code = io.open(path, 'rb')

  if nil == handle then
    -- ENOENT (2) and ENOTDIR (20): the file is not there, or a component
    -- of the path is not a directory. Both mean "no secrets here".
    if 2 == code or 20 == code then
      return nil, nil
    end
    return nil, ((why or 'cannot read'):gsub('^.-: ', ''))
  end

  local text = handle:read('a')
  handle:close()

  if nil == text then
    return nil, 'cannot read'
  end

  return text
end

M.readfile = readfile

-- ------------------------------------------------------- built-in kinds
--
-- The criterion for "built in" is needing nothing of the platform beyond
-- reading a local file: no socket, no TLS, no crypto, no child process.

--- Environment variables: `api.token` from `API_TOKEN`.
function M.env(prefix, source)
  return {
    lookup = function(secret)
      local key = name.envkey(secret, prefix)
      if nil == source then
        return os.getenv(key)
      end
      return source[key]
    end,
    describe = function()
      return 'env' .. (nonempty(prefix) and (':' .. prefix) or '')
    end,
  }
end

--- A `.env` file, read once, keyed exactly like the environment.
---
--- Loaded LAZILY. The `stores` corpus group puts a dotenv provider in a
--- chain and never looks anything up; an eager constructor would read
--- whatever `.env` happens to sit in the working directory.
function M.dotenv(file, prefix)
  local usefile = file or '.env'
  local values = nil

  local function load()
    if nil ~= values then
      return values
    end

    local text, why = readfile(usefile)

    if nil == text then
      if nil ~= why then
        fail('sekreto: dotenv provider cannot read ' .. usefile .. ': ' .. why)
      end
      -- An absent file, or an absent directory, means "no secrets here",
      -- exactly like the file provider.
      values = {}
    else
      values = name.parsedotenv(text)
    end

    return values
  end

  return {
    lookup = function(secret)
      return load()[name.envkey(secret, prefix)]
    end,
    describe = function()
      return 'dotenv:' .. usefile
    end,
  }
end

--- Literal values, keyed like environment variables. The shared spec uses
--- this to test chain behaviour without touching the outside world.
function M.memory(values, prefix)
  local usevalues = values or {}

  return {
    lookup = function(secret)
      return usevalues[name.envkey(secret, prefix)]
    end,
    describe = function()
      return 'memory' .. (nonempty(prefix) and (':' .. prefix) or '')
    end,
  }
end

--- A directory of one-secret-per-file entries, keyed like the
--- environment: `api.token` reads `<dir>/API_TOKEN`.
---
--- This is the shape of a mounted Kubernetes Secret, a Docker or Swarm
--- secret, and a systemd credentials directory, so those all work with no
--- further configuration. Read on every lookup, never cached. One
--- trailing newline is stripped - tools that write these files disagree
--- about it, and a newline is never part of a secret on purpose.
function M.file(dir, prefix)
  local usedir = dir or ''

  return {
    lookup = function(secret)
      local path = ('' == usedir) and name.envkey(secret, prefix)
        or (trimslash(usedir) .. '/' .. name.envkey(secret, prefix))

      local text, why = readfile(path)

      if nil == text then
        if nil ~= why then
          fail('sekreto: file provider cannot read ' .. path .. ': ' .. why)
        end
        return nil
      end

      if '\r\n' == text:sub(-2) then
        return text:sub(1, #text - 2)
      end
      if '\n' == text:sub(-1) then
        return text:sub(1, #text - 1)
      end

      return text
    end,
    describe = function()
      return 'file:' .. usedir
    end,
  }
end

-- ------------------------------ providers as voxgig/plugin definitions

--- The export key under which a provider definition publishes the
--- provider it built. `Sekreto` reads `<ref>/provider` off the host.
M.PROVIDER_EXPORT = 'provider'

--- The voxgig/plugin error code a SekretoError travels under when it is
--- raised inside a definition's `define`.
---
--- plugin wraps a code-less error raised by a callback as
--- `plugin_define_failed`, and keeps an error that already carries a
--- code. A provider that refuses its own configuration - `kv: 3`, a
--- missing project - raises a SekretoError, and that message is pinned by
--- the spec byte for byte, so it must come back out of the host exactly
--- as it went in. `providerplugin` gives it this code on the way in;
--- `Sekreto` turns it back into a SekretoError on the way out.
M.ERROR_CODE = 'sekreto_error'

--- A provider kind, as a voxgig/plugin definition.
---
--- This is the whole bridge between the two libraries. The definition's
--- `name` is the `kind` a spec names; its `define` reads the spec as
--- `inst:options()`, builds the provider with `make`, and exports it.
--- Nothing runs at `activate`: a provider opens nothing until its first
--- lookup, so there is nothing to capture - a provider that does hold a
--- resource acquires it there and lets the instance scope unwind it.
---
--- Every built-in and every plugin is made this way, so a custom provider
--- kind is one call:
---
---     providerplugin('mystore', function(spec) return mystore(spec.addr) end)
---
--- ONLY a SekretoError is re-raised with a code. Anything else a `make`
--- raises is not sekreto's to rewrite: it leaves this function as it
--- arrived, code-less, and the host wraps it as `plugin_define_failed`
--- naming the instance.
function M.providerplugin(kind, make)
  return {
    name = kind,
    define = function(inst)
      local ok, built = pcall(make, inst:options() or {})

      if not ok then
        if err.issekretoerror(built) then
          local message = err.message(built)
          plugin.types.fail(M.ERROR_CODE, message,
            plugin.types.map({ ref = inst.ref, cause = message }))
        end
        error(built, 0)
      end

      inst:export(M.PROVIDER_EXPORT, built)
    end,
  }
end

--- The four built-in provider kinds - the same four in every port. What
--- makes a kind built in is that it reads at most a local file: no
--- socket, no TLS, no crypto, no child process.
M.BUILTINS = {
  M.providerplugin('env', function(spec) return M.env(spec.prefix) end),
  M.providerplugin('memory', function(spec)
    return M.memory(spec.values or {}, spec.prefix)
  end),
  M.providerplugin('dotenv', function(spec)
    return M.dotenv(spec.file or '.env', spec.prefix)
  end),
  M.providerplugin('file', function(spec)
    return M.file(spec.dir or '', spec.prefix)
  end),
}

--- Every kind this library ships, built in or as a plugin, so that a kind
--- sekreto has never heard of can be told from one that was not passed
--- in.
M.KINDS = {
  builtin = { 'env', 'memory', 'dotenv', 'file' },
  plugin = {
    'hashicorp', 'boru', 'awssecrets', 'awsparams', 'gcpsecrets',
    'azuresecrets', 'onepassword', 'doppler', 'infisical', 'secretspec',
  },
}

return M
