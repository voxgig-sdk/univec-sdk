-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lua/src/sekreto/plugins/aws.lua)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
-- The aws plugin: Secrets Manager and SSM Parameter Store, two kinds in
-- one module because they share SigV4 request signing and one signed
-- call.
--
-- SIGV4 TRAVELS WITH THIS PLUGIN. It is the crypto edge - HMAC-SHA256 -
-- and the core of no port imports a hash function, so
-- sekreto.plugins.sigv4 and the SHA-256 in sekreto.plugins.crypto behind
-- it are reached from here and from nowhere else in the library.
--
-- A port of typescript/plugins/aws.ts, which is canonical.

local err = require('feature.secrets.sekreto.err')
local name = require('feature.secrets.sekreto.name')
local addr = require('feature.secrets.sekreto.addr')
local providers = require('feature.secrets.sekreto.providers')
local json = require('feature.secrets.sekreto.plugins.json')
local httpjson = require('feature.secrets.sekreto.plugins.httpjson')
local support = require('feature.secrets.sekreto.plugins.support')
local crypto = require('feature.secrets.sekreto.plugins.crypto')
local sigv4 = require('feature.secrets.sekreto.plugins.sigv4')

local fail = err.fail
local trimslash = providers.trimslash
local providerplugin = providers.providerplugin
local first = support.first
local awsnow = support.awsnow
local fetchjson = httpjson.fetchjson

local M = {}

--- Region and credentials, from config first and the standard AWS_*
--- environment variables second. Missing either is an error: an AWS store
--- with no credentials could not answer.
local function awsauth(region, keyid, secret, session)
  local useregion = first(region, os.getenv('AWS_REGION'), os.getenv('AWS_DEFAULT_REGION'))
  local usekeyid = first(keyid, os.getenv('AWS_ACCESS_KEY_ID'))
  local usesecret = first(secret, os.getenv('AWS_SECRET_ACCESS_KEY'))
  local usesession = first(session, os.getenv('AWS_SESSION_TOKEN'))

  if '' == useregion then
    fail('sekreto: aws: no region (set region or AWS_REGION)')
  end
  if '' == usekeyid or '' == usesecret then
    fail('sekreto: aws: no credentials' ..
      ' (set keyid/secret or AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY)')
  end

  return {
    region = useregion,
    keyid = usekeyid,
    secret = usesecret,
    session = ('' == usesession) and nil or usesession,
  }
end

M.awsauth = awsauth

--- One signed call to an AWS JSON-1.1 API.
local function awscall(region, keyid, secret, session, useaddr, service, target, payload)
  local auth = awsauth(region, keyid, secret, session)

  -- The China partition lives under its own suffix; every other
  -- commercial region is plain amazonaws.com.
  local suffix = ('cn-' == auth.region:sub(1, 3)) and '.amazonaws.com.cn'
    or '.amazonaws.com'
  local address = first(useaddr, 'https://' .. service .. '.' .. auth.region .. suffix)
  addr.checkaddr(address)

  local url = trimslash(address) .. '/'

  local extras = {
    { 'content-type', 'application/x-amz-json-1.1' },
    { 'x-amz-target', target },
  }

  local signed = sigv4.sigv4({
    method = 'POST',
    url = url,
    service = service,
    region = auth.region,
    keyid = auth.keyid,
    secret = auth.secret,
    datetime = awsnow(),
    headers = extras,
    body = payload,
    session = auth.session,
  })

  local headers = {}
  for _, pair in ipairs(extras) do
    headers[#headers + 1] = pair
  end
  for _, pair in ipairs(signed) do
    headers[#headers + 1] = pair
  end

  return fetchjson('POST', url, headers, payload)
end

--- Does this AWS error body name one of the not-found types? Those are a
--- miss; every other failure is a store that could not answer.
local function awsmiss(body, ...)
  local errtype = json.asstr(json.dig(body, '__type'))
  if nil == errtype then
    return false
  end

  for _, want in ipairs({ ... }) do
    if nil ~= errtype:find(want, 1, true) then
      return true
    end
  end

  return false
end

M.awsmiss = awsmiss

--- AWS Secrets Manager.
---
--- `api.token` reads the secret named `api` (the vaultref path) and takes
--- the `token` field of its JSON SecretString - the AWS idiom of one JSON
--- map per secret. A SecretString that is not JSON is the value itself,
--- under the conventional field `value`.
local function awssecrets(region, keyid, secret, session, useaddr)
  return {
    lookup = function(name_)
      local ref = name.vaultref(name_)

      local res = awscall(
        region, keyid, secret, session, useaddr,
        'secretsmanager', 'secretsmanager.GetSecretValue',
        json.stringify(json.obj({ { 'SecretId', ref.path } }))
      )

      if 400 == res.status and awsmiss(res.body, 'ResourceNotFoundException') then
        return nil
      end

      if 200 ~= res.status then
        fail('sekreto: aws secretsmanager error: ' .. res.status)
      end

      local text = json.asstr(json.dig(res.body, 'SecretString'))

      if nil == text then
        -- A binary secret has no fields to address; only the conventional
        -- `value` field can mean "the bytes themselves".
        local bin = json.asstr(json.dig(res.body, 'SecretBinary'))
        if nil ~= bin and 'value' == ref.field then
          local decoded = crypto.unbase64(bin)
          if nil == decoded then
            fail('sekreto: aws secretsmanager: undecodable secret')
          end
          return decoded
        end
        return nil
      end

      local parsed = json.parse(text)

      if json.isobj(parsed) then
        return json.text(parsed.vals[ref.field])
      end

      -- A plain-string secret is the whole value; it has no named fields.
      if 'value' == ref.field then
        return text
      end

      return nil
    end,
    -- Config only, never the environment: describe() feeds the spec's
    -- sources group, which must answer the same everywhere.
    describe = function()
      return 'awssecrets:' .. (region or '')
    end,
  }
end

--- AWS SSM Parameter Store.
---
--- `db.pass.main` reads the parameter `/db/pass/main` (under an optional
--- prefix path), decrypted. Parameter Store carries flat strings, so
--- there is no field indirection.
local function awsparams(region, keyid, secret, session, useaddr, prefix)
  return {
    lookup = function(name_)
      local payload = json.obj({
        { 'Name', name.awsparam(name_, prefix) },
        { 'WithDecryption', true },
      })

      local res = awscall(
        region, keyid, secret, session, useaddr,
        'ssm', 'AmazonSSM.GetParameter', json.stringify(payload)
      )

      if 400 == res.status and awsmiss(res.body, 'ParameterNotFound') then
        return nil
      end

      if 200 ~= res.status then
        fail('sekreto: aws ssm error: ' .. res.status)
      end

      return json.text(json.dig(res.body, 'Parameter', 'Value'))
    end,
    describe = function()
      return 'awsparams:' .. (region or '') .. (prefix or '')
    end,
  }
end

--- The two kinds, as voxgig/plugin definitions.
M.awssecrets = providerplugin('awssecrets', function(spec)
  return awssecrets(spec.region, spec.keyid, spec.secret, spec.session, spec.addr)
end)

M.awsparams = providerplugin('awsparams', function(spec)
  return awsparams(spec.region, spec.keyid, spec.secret, spec.session,
    spec.addr, spec.prefix)
end)

return M
