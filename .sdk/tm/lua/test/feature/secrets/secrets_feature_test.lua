-- Univec SDK secrets feature test
--
-- Behavioural tests for the secrets feature (vendored @voxgig/sekreto) -
-- the lua port of tm/go/test/feature/secrets/secrets_feature_test.go.
--
-- The contract under test: the `apikey` OPTION keeps its exact old meaning
-- and always wins, because the feature places it FIRST in the provider
-- chain (a `memory` store named `options`) - explicit-beats-lookup falls
-- out of sekreto's first-hit rule rather than from special-case logic.
-- With the feature inactive nothing changes at all. With it active and the
-- option unset, the chain (a memory store, a custom provider, a vault)
-- supplies the credential instead.
--
-- This file lives in the test `feature/` container on purpose: `target
-- add` trims it, along with the feature source and the vendored library,
-- for a project whose model does not select `secrets`.
--
-- HOW EVERY CASE IS BUILT, and why:
--
--   * a LIVE client (`sdk.new`), so `system.fetch` really is the transport
--     and the credential is asserted ON THE WIRE - an options-level
--     assertion passes for a port that never consults the value;
--   * the feature handed in through `extend` unless the generated config
--     already installed it, so the suite holds in any generated tree;
--   * a refusal asserted on sekreto's OWN message, never on "some error";
--   * and a CONTROL leg beside every refusal: the same construction with a
--     working provider must reach the same transport EXACTLY ONCE, so a
--     zero on the refused side means REFUSED rather than UNWIRED.
--
-- Two things Lua cannot do that the other ports' suites do. It cannot set
-- an environment variable, so the chain's stores are `memory`, `file` and
-- custom providers rather than `env`; and it cannot spell `auth = nil` in
-- an options table (a table stores no nil, and validate then fills the
-- default), so the suppression is exercised in the one form that IS
-- expressible - clearing `client.options.auth` after construction - and
-- pinned there.

local sdk = require("project-name-_sdk")
local SecretsFeature = require("feature.secrets_feature")
local sekreto = require("feature.secrets.sekreto")


-- ---------------------------------------------------------------------
-- The recording transport: system.fetch for a LIVE client, scripting one
-- status per API call (the last repeating) and a token endpoint for the
-- exchange tests.

local function make_wire(script)
  script = script or {}
  local w = {
    calls = {},
    apistatus = script.apistatus or { 200 },
    tokens = script.tokens or { "ACCESS01", "ACCESS02", "ACCESS03" },
    tokenpath = "auth/token",
    respfield = script.respfield or "access_token",
    issued = 0,
    apicalls = 0,
  }

  local function is_token(url)
    local suffix = "/" .. w.tokenpath
    return url:sub(-#suffix) == suffix
  end

  w.fetch = function(url, fetchdef)
    local headers = type(fetchdef) == "table" and fetchdef.headers or {}
    local auth = headers["authorization"]
    w.calls[#w.calls + 1] = {
      url = url, auth = auth, has = auth ~= nil,
      body = fetchdef.body, method = fetchdef.method,
    }

    if is_token(url) then
      local token = w.tokens[math.min(w.issued + 1, #w.tokens)]
      w.issued = w.issued + 1
      local payload = { [w.respfield] = token }
      return {
        status = 200, statusText = "OK", headers = {},
        json = function() return payload end,
      }, nil
    end

    local status = w.apistatus[math.min(w.apicalls + 1, #w.apistatus)]
    w.apicalls = w.apicalls + 1
    local payload = { ok = status < 400 }
    return {
      status = status, statusText = "X", headers = {},
      json = function() return payload end,
    }, nil
  end

  -- The recorded calls that did NOT go to the token endpoint.
  function w.api()
    local out = {}
    for _, c in ipairs(w.calls) do
      if not is_token(c.url) then out[#out + 1] = c end
    end
    return out
  end

  function w.token()
    local out = {}
    for _, c in ipairs(w.calls) do
      if is_token(c.url) then out[#out + 1] = c end
    end
    return out
  end

  return w
end


-- ---------------------------------------------------------------------
-- Support.

-- The Authorization header carries the SPEC's credential prefix, which a
-- TEMPLATE cannot know - so assert on the CREDENTIAL and let the prefix be
-- whatever this SDK's API declares.
local function assert_credential(header, token)
  local ok = header == token
    or (type(header) == "string" and header:sub(-(#token + 1)) == " " .. token)
  assert.is_true(ok, "expected the authorization header to carry " .. token ..
    ", got: " .. tostring(header))
end


local function secrets_feature_of(client)
  for _, f in ipairs(client.features) do
    if f.name == "secrets" then return f end
  end
  return nil
end


-- A live provider, as a caller would hand one in: a table with a callable
-- `lookup` (sekreto's duck-typed shape) and a `describe`.
local function custom_provider(lookup, label)
  return {
    lookup = lookup,
    describe = function() return label or "custom" end,
  }
end

local function working_provider(value)
  return custom_provider(function(_name) return value end, "working")
end

local function broken_provider(message)
  return custom_provider(function(_name)
    error(sekreto.SekretoError(message), 0)
  end, "broken")
end


-- A LIVE client carrying the secrets feature via the `extend` seam, wired
-- to the recording transport. The feature is adopted via `extend` ONLY
-- when the generated config did not already install it - when this SDK
-- was generated with `secrets` model-active, the ordinary factory path
-- builds the instance, and adding a second via extend would DOUBLE the
-- feature: two transport wraps, two resolutions, and a token purchase the
-- assertions cannot account for.
local function secrets_client(w, sdkopts)
  local function build(extend)
    local opts = {
      base = "http://secrets.test/api",
      system = { fetch = w.fetch },
    }
    for k, v in pairs(sdkopts or {}) do opts[k] = v end
    if extend then
      opts.extend = { SecretsFeature.new() }
    end
    return sdk.new(opts)
  end

  local client = build(false)
  if secrets_feature_of(client) == nil then
    client = build(true)
  end
  return client
end


-- Feature options with a chain: the given providers, or a memory store
-- holding `value` under the default secret name.
local function chain(providers, extra)
  local fopts = { active = true, providers = providers }
  for k, v in pairs(extra or {}) do fopts[k] = v end
  return { secrets = fopts }
end

local function memory(value, name)
  return { kind = "memory", name = name, values = { APIKEY = value } }
end


-- The entity accessors this SDK generated, found from the client's own
-- config: this file is a TEMPLATE and no project's entity names are known
-- here. Accessors are PascalCase methods on the SDK class.
local function entity_accessors(client)
  local class = getmetatable(client).__index
  local out = {}
  for name, _ in pairs(client:options_map().entity or {}) do
    local flat = name:gsub("_", ""):lower()
    for k, v in pairs(class) do
      if type(v) == "function" and k:match("^%u") and k:lower() == flat then
        out[#out + 1] = k
      end
    end
  end
  table.sort(out)
  return out
end


-- Perform real entity operations - which is what runs the request
-- pipeline - until `stop` reports the observable state a test is waiting
-- for. Each op's own outcome is irrelevant (no seeded data, a scripted
-- response); an op the API does not define fails BEFORE the transport,
-- which is why several may need driving. Returns the last (res, err).
local function drive_entity_op_until(client, what, stop)
  local last_res, last_err = nil, nil
  for _, accessor in ipairs(entity_accessors(client)) do
    local ent = client[accessor](client)
    for _, opname in ipairs({ "list", "load" }) do
      if type(ent[opname]) == "function" then
        last_res, last_err = ent[opname](ent, { id = "id01" })
        if stop() then return last_res, last_err end
      end
    end
  end
  error("no entity operation " .. what .. " - nothing to assert on", 0)
end

-- Drive ops until one request reached the recorder.
local function drive_entity_op(client, w)
  local before = #w.api()
  return drive_entity_op_until(client, "reached the transport",
    function() return before < #w.api() end)
end

-- Drive ops until the chain was consulted, and hand back the op's error.
local function drive_refusal(client, asked)
  local _, err = drive_entity_op_until(client, "consulted the chain", asked)
  return err
end


-- ---------------------------------------------------------------------

describe("secrets", function()

  -- The feature-inactive baseline: bit-identical behaviour.
  describe("inactive", function()

    it("apikey option behaves exactly as before", function()
      local client = sdk.test(nil, { apikey = "OPTKEY01" })
      local fetchdef, err = client:prepare({ path = "/" })
      assert.is_nil(err)
      assert_credential(fetchdef.headers["authorization"], "OPTKEY01")
      assert.is_nil(secrets_feature_of(client),
        "no model activation, no extend: the feature must not be installed")
    end)

    it("no apikey means no authorization header", function()
      local client = sdk.test(nil, nil)
      local fetchdef, err = client:prepare({ path = "/" })
      assert.is_nil(err)
      assert.is_nil(fetchdef.headers["authorization"])
    end)

    it("an inactive feature wraps nothing and resolves nothing", function()
      local w = make_wire()
      local client = sdk.new({
        base = "http://secrets.test/api",
        system = { fetch = w.fetch },
        feature = { secrets = { active = false, providers = { memory("CHAIN00") } } },
        extend = { SecretsFeature.new() },
      })
      client:direct({ path = "/probe" })
      assert.are.equal(1, #w.api())
      assert.is_false(w.api()[1].has, "an inactive feature must not resolve a credential")
    end)
  end)


  -- Active: the provider chain, driven through real entity operations.
  describe("chain", function()

    it("apikey option still wins over the chain", function()
      local w = make_wire()
      local client = secrets_client(w, {
        apikey = "OPTKEY01",
        feature = chain({ memory("CHAIN01") }),
      })

      drive_entity_op(client, w)
      assert_credential(w.api()[1].auth, "OPTKEY01")

      -- The explicit option is a real store, not a special case: a
      -- directed read names it like any other.
      local sf = secrets_feature_of(client)
      assert.is_not_nil(sf, "the extend seam did not install the feature")
      assert.are.equal("OPTKEY01", sf:sekreto():getfrom("options", "apikey"))
    end)

    it("an omitted apikey defers to the chain at the transport seam", function()
      local w = make_wire()
      local client = secrets_client(w, { feature = chain({ memory("CHAIN02") }) })

      -- Before any op, nothing has been resolved.
      assert.is_nil(secrets_feature_of(client):credential())

      drive_entity_op(client, w)

      -- Resolution happens AT THE TRANSPORT - the one seam every wire
      -- path crosses - so the credential is on the wire, not merely
      -- resolved. The feature holds it; the options map is never written.
      assert_credential(w.api()[1].auth, "CHAIN02")
      assert.are.equal("CHAIN02", secrets_feature_of(client):credential())
      assert.are.equal("", client:options_map().apikey,
        "the options map must stay unwritten")
    end)

    it("custom provider objects are accepted verbatim", function()
      local asked = {}
      local w = make_wire()
      local client = secrets_client(w, {
        feature = chain({
          custom_provider(function(name)
            asked[#asked + 1] = name
            return "CUSTOM01"
          end),
        }),
      })

      drive_entity_op(client, w)
      assert_credential(w.api()[1].auth, "CUSTOM01")
      assert.are.equal("apikey", asked[1])
    end)

    it("a miss everywhere leaves the header off", function()
      local w = make_wire()
      local client = secrets_client(w, {
        feature = chain({ { kind = "memory", values = {} } }),
      })

      drive_entity_op(client, w)
      assert.is_false(w.api()[1].has,
        "a chain MISS must fall through to an unauthenticated request, got " ..
        tostring(w.api()[1].auth))
    end)

    it("a miss falls through to the next provider", function()
      local asked = false
      local w = make_wire()
      local client = secrets_client(w, {
        feature = chain({
          custom_provider(function(_name) asked = true; return nil end, "empty"),
          memory("CHAIN04"),
        }),
      })

      drive_entity_op(client, w)
      assert.is_true(asked, "the first provider was never consulted")
      assert_credential(w.api()[1].auth, "CHAIN04")
    end)

    it("a provider ERROR fails the op and nothing reaches the wire", function()
      local asked = false
      local w = make_wire()
      local client = secrets_client(w, {
        feature = chain({
          custom_provider(function(_name)
            asked = true
            error(sekreto.SekretoError("sekreto: vault unreachable"), 0)
          end, "broken"),
        }),
      })

      local err = drive_refusal(client, function() return asked end)

      -- The entity pipeline turns the refusal into the SDK error carrying
      -- the provider's OWN message - never a silent unauthenticated send.
      assert.is_table(err, "the entity path did not surface the refusal")
      assert.is_truthy(tostring(err):find("sekreto: vault unreachable", 1, true),
        "the refusal must carry the provider's own message, got: " .. tostring(err))
      assert.are.equal(0, #w.api(),
        "a broken vault must never yield a request: " .. #w.api() .. " calls went out")

      -- CONTROL: the same construction with a working provider reaches
      -- the same transport exactly once, so the zero above is REFUSED,
      -- not UNWIRED.
      local control = make_wire()
      local ok_client = secrets_client(control, { feature = chain({ working_provider("CTRL01") }) })
      drive_entity_op(ok_client, control)
      assert.are.equal(1, #control.api(), "the control operation did not reach system.fetch exactly once")
      assert_credential(control.api()[1].auth, "CTRL01")
    end)

    it("an error fails the op even though a later provider has the secret", function()
      local w = make_wire()
      local client = secrets_client(w, {
        feature = chain({
          broken_provider("sekreto: vault unreachable"),
          memory("CHAIN05"),
        }),
      })

      local res = client:direct({ path = "/probe" })
      assert.is_false(res.ok, "an ERROR must not fall through to the next provider")
      assert.is_truthy(tostring(res.err):find("sekreto: vault unreachable", 1, true),
        "expected the provider's own message, got: " .. tostring(res.err))
      assert.are.equal(0, #w.api())
    end)

    it("a broken store does not poison the client after it recovers", function()
      local broken = true
      local w = make_wire()
      local client = secrets_client(w, {
        feature = chain({
          custom_provider(function(_name)
            if broken then error(sekreto.SekretoError("sekreto: vault unreachable"), 0) end
            return "RECOVERED01"
          end, "flaky"),
        }),
      })

      local res = client:direct({ path = "/probe" })
      assert.is_false(res.ok)
      assert.are.equal(0, #w.api())

      broken = false
      res = client:direct({ path = "/probe" })
      assert.is_true(res.ok, "the recovered chain must serve the next request: " .. tostring(res.err))
      assert.are.equal(1, #w.api())
      assert_credential(w.api()[1].auth, "RECOVERED01")
    end)

    it("the file built-in reads a mounted secret directory", function()
      local dir = os.tmpname()
      os.remove(dir)
      local made = os.execute("mkdir -p '" .. dir .. "'")
      assert.is_true(made == true or made == 0, "could not make " .. dir)
      local fh = assert(io.open(dir .. "/APIKEY", "wb"))
      fh:write("FILEKEY01\n")
      fh:close()

      local w = make_wire()
      local client = secrets_client(w, { feature = chain({ { kind = "file", dir = dir } }) })
      drive_entity_op(client, w)
      assert_credential(w.api()[1].auth, "FILEKEY01")

      os.remove(dir .. "/APIKEY")
      os.remove(dir)
    end)
  end)


  -- The raw paths run no feature hooks at all; resolution at the transport
  -- is what gives them the same credential - and the same refusal.
  describe("raw paths", function()

    it("direct() carries the chain-resolved credential", function()
      local w = make_wire()
      local client = secrets_client(w, { feature = chain({ memory("RAWKEY01") }) })
      local res = client:direct({ path = "/probe" })
      assert.is_true(res.ok)
      assert.are.equal(1, #w.api())
      assert_credential(w.api()[1].auth, "RAWKEY01")
    end)

    it("graphql() carries the chain-resolved credential", function()
      local w = make_wire()
      local client = secrets_client(w, { feature = chain({ memory("RAWKEY02") }) })
      local res = client:graphql("{ thing }", {})
      assert.is_true(res.ok, tostring(res.err))
      assert.are.equal(1, #w.api())
      assert_credential(w.api()[1].auth, "RAWKEY02")
      assert.are.equal("POST", w.api()[1].method)
    end)

    it("direct() is refused on a provider error, with the provider's message", function()
      local w = make_wire()
      local client = secrets_client(w, {
        feature = chain({ broken_provider("sekreto: vault unreachable") }),
      })
      local res = client:direct({ path = "/probe" })
      assert.is_false(res.ok)
      assert.is_truthy(tostring(res.err):find("sekreto: vault unreachable", 1, true),
        "got: " .. tostring(res.err))
      assert.are.equal(0, #w.api())

      -- CONTROL, through the same raw path.
      local control = make_wire()
      local ok_client = secrets_client(control, { feature = chain({ working_provider("RAWCTRL01") }) })
      local ok_res = ok_client:direct({ path = "/probe" })
      assert.is_true(ok_res.ok)
      assert.are.equal(1, #control.api())
      assert_credential(control.api()[1].auth, "RAWCTRL01")
    end)

    it("graphql() is refused on a provider error, with the provider's message", function()
      local w = make_wire()
      local client = secrets_client(w, {
        feature = chain({ broken_provider("sekreto: vault unreachable") }),
      })
      local res = client:graphql("{ thing }", {})
      assert.is_false(res.ok)
      assert.is_truthy(tostring(res.err):find("sekreto: vault unreachable", 1, true),
        "got: " .. tostring(res.err))
      assert.are.equal(0, #w.api())

      local control = make_wire()
      local ok_client = secrets_client(control, { feature = chain({ working_provider("RAWCTRL02") }) })
      local ok_res = ok_client:graphql("{ thing }", {})
      assert.is_true(ok_res.ok)
      assert.are.equal(1, #control.api())
      assert_credential(control.api()[1].auth, "RAWCTRL02")
    end)
  end)


  -- Construction failure is a refusal, never a shortened chain.
  describe("init failure gate", function()

    local NOTAPROVIDER = "not a provider or a provider spec"

    local function refused_with(providers, fragment)
      local w = make_wire()
      local client = secrets_client(w, { feature = chain(providers) })

      local sf = secrets_feature_of(client)
      assert.is_not_nil(sf:init_error(), "construction must record the failure")

      local res = client:direct({ path = "/probe" })
      assert.is_false(res.ok, "a client whose chain could not be built must refuse")
      assert.is_truthy(tostring(res.err):find(fragment, 1, true),
        "expected sekreto's own message (" .. fragment .. "), got: " .. tostring(res.err))
      assert.are.equal(0, #w.api(), "nothing may reach the wire")

      local err = drive_refusal(client, function() return true end)
      assert.is_table(err, "the entity path must refuse too")
      assert.is_truthy(tostring(err):find(fragment, 1, true), "got: " .. tostring(err))
      assert.are.equal(0, #w.api())
    end

    it("a bare kind name in providers is refused, not dropped", function()
      -- CONTROL FIRST, so the zero below is known to be observable.
      local control = make_wire()
      local ok_client = secrets_client(control, { feature = chain({ working_provider("INITKEY01") }) })
      drive_entity_op(ok_client, control)
      assert.are.equal(1, #control.api())
      assert_credential(control.api()[1].auth, "INITKEY01")

      refused_with({ "hashicorp" }, NOTAPROVIDER)
    end)

    it("a number in providers is refused, not dropped", function()
      refused_with({ 42 }, NOTAPROVIDER)
    end)

    it("a nil hole in providers does not shorten the chain", function()
      -- `{ spec, nil, spec }` ends ipairs after the first entry: the second
      -- store would silently vanish. The feature walks to the highest key.
      local providers = { memory("HOLE01") }
      providers[3] = memory("HOLE03")
      refused_with(providers, NOTAPROVIDER)
    end)

    it("a kind this SDK was not generated with is refused with sekreto's message", function()
      -- `nosuchkind` is not built in and no plugin group provides it.
      refused_with({ { kind = "nosuchkind" } }, "unknown provider kind: nosuchkind")
    end)

    it("an invalid secret name is refused, not skipped", function()
      local w = make_wire()
      local client = secrets_client(w, {
        apikey = "OPTKEY01",
        feature = chain({ memory("X") }, { name = "not a name" }),
      })
      local res = client:direct({ path = "/probe" })
      assert.is_false(res.ok)
      assert.is_truthy(tostring(res.err):find("sekreto: invalid name", 1, true),
        "got: " .. tostring(res.err))
      assert.are.equal(0, #w.api())
    end)
  end)


  -- What lua ships of the plugin tier depends on the groups the model
  -- activated. Either way the boundary is asserted, and either way with
  -- sekreto's own message.
  describe("plugin kinds", function()

    local has_hashicorp = pcall(require, "feature.secrets.sekreto.plugins.hashicorp")

    if has_hashicorp then
      it("the vault group's kinds are in this SDK's provider vocabulary", function()
        local w = make_wire()
        local client = secrets_client(w, { feature = chain({ memory("K") }) })
        local sek = secrets_feature_of(client):sekreto()
        assert.is_true(sek.catalog:has("hashicorp"))
        assert.is_true(sek.catalog:has("boru"))
      end)

      it("the transport helper is built where net.lua looks for it", function()
        local net = require("feature.secrets.sekreto.plugins.net")
        local fh = io.open(net.HELPER, "rb")
        assert.is_not_nil(fh, "make build did not produce " .. net.HELPER)
        fh:close()
      end)

      it("a hashicorp provider reaches the helper and an unreachable vault is an ERROR", function()
        -- Port 9 (discard) is closed on any sane host: the helper answers
        -- "connection refused", httpjson raises sekreto's `cannot reach`,
        -- and the request is refused with zero calls. A helper that was
        -- never built answers "did not answer" instead - a different
        -- message, so the assertion tells the two apart.
        local w = make_wire()
        local client = secrets_client(w, {
          feature = chain({
            { kind = "hashicorp", addr = "http://127.0.0.1:9", token = "t0" },
          }),
        })
        local res = client:direct({ path = "/probe" })
        assert.is_false(res.ok)
        local msg = tostring(res.err)
        assert.is_truthy(msg:find("sekreto: cannot reach ", 1, true)
          and msg:find("127.0.0.1:9", 1, true)
          and msg:find("connection refused", 1, true),
          "expected the transport failure from the helper, got: " .. msg)
        assert.is_falsy(msg:find("did not answer", 1, true),
          "the helper was not run: " .. msg)
        assert.are.equal(0, #w.api())
      end)
    else
      it("a plugin kind that was not generated is refused with sekreto's message", function()
        local w = make_wire()
        local client = secrets_client(w, {
          feature = chain({
            { kind = "hashicorp", addr = "http://127.0.0.1:9", token = "t0" },
          }),
        })
        local res = client:direct({ path = "/probe" })
        assert.is_false(res.ok)
        assert.is_truthy(tostring(res.err):find(
          "hashicorp is a sekreto plugin, not built in", 1, true),
          "got: " .. tostring(res.err))
        assert.are.equal(0, #w.api())
      end)
    end
  end)


  -- The one auth suppression lua can express.
  describe("auth suppression", function()

    it("clearing options.auth suppresses the chain credential on the entity path", function()
      local w = make_wire()
      local client = secrets_client(w, { feature = chain({ memory("LEAK01") }) })
      client.options.auth = nil

      drive_entity_op(client, w)
      assert.is_false(w.api()[1].has,
        "suppressed auth must send no credential, got " .. tostring(w.api()[1].auth))
    end)

    it("clearing options.auth suppresses the chain credential on direct()", function()
      local w = make_wire()
      local client = secrets_client(w, { feature = chain({ memory("LEAK02") }) })
      client.options.auth = nil

      local res = client:direct({ path = "/probe" })
      assert.is_true(res.ok)
      assert.is_false(w.api()[1].has, "got " .. tostring(w.api()[1].auth))
    end)

    it("an options-level auth = nil is NOT expressible: validate fills the default", function()
      -- Pinned so the limitation is a recorded fact rather than a surprise:
      -- `{ auth = nil }` is the same table as `{}`, and make_options then
      -- supplies the optspec default. The post-construction clear above is
      -- the suppression this target has.
      local client = sdk.test(nil, { apikey = "OPTKEY01", auth = nil })
      assert.is_table(client:options_map().auth)
    end)
  end)


  describe("cache", function()

    it("caches the resolved credential by default", function()
      local asked = 0
      local w = make_wire()
      local client = secrets_client(w, {
        feature = chain({
          custom_provider(function(_name) asked = asked + 1; return "V" .. asked end),
        }),
      })
      client:direct({ path = "/a" })
      client:direct({ path = "/b" })
      assert.are.equal(2, #w.api())
      assert.are.equal(1, asked, "the chain must be asked once while caching")
      assert_credential(w.api()[2].auth, "V1")
    end)

    it("cache = false asks the chain once per request", function()
      local asked = 0
      local w = make_wire()
      local client = secrets_client(w, {
        feature = chain({
          custom_provider(function(_name) asked = asked + 1; return "V" .. asked end),
        }, { cache = false }),
      })
      client:direct({ path = "/a" })
      client:direct({ path = "/b" })
      assert.are.equal(2, asked)
      assert_credential(w.api()[1].auth, "V1")
      assert_credential(w.api()[2].auth, "V2")
    end)

    it("an uncached miss after a hit RETRACTS the credential", function()
      local value = "REVOCABLE01"
      local w = make_wire()
      local client = secrets_client(w, {
        feature = chain({
          custom_provider(function(_name) return value end),
        }, { cache = false }),
      })
      client:direct({ path = "/a" })
      assert_credential(w.api()[1].auth, "REVOCABLE01")

      value = nil
      client:direct({ path = "/b" })
      assert.is_false(w.api()[2].has,
        "after the chain reports a miss the retracted credential must not go out; the wire saw " ..
        tostring(w.api()[2].auth))
    end)
  end)


  describe("sekreto accessor", function()

    it("is the live instance", function()
      local w = make_wire()
      local client = secrets_client(w, { feature = chain({ memory("LIVEKEY0001") }) })
      local sf = secrets_feature_of(client)
      assert.are.equal(sf:sekreto(), sf:sekreto())
      assert.are.equal("LIVEKEY0001", sf:sekreto():get("apikey"))
      local redacted = sf:sekreto():redact("token LIVEKEY0001 here")
      assert.is_truthy(redacted:find("[redacted]", 1, true),
        "redact did not cover a resolved value: " .. redacted)
    end)
  end)


  describe("exchange", function()

    local function exchange_client(w, extra, sdkextra)
      local fopts = {
        providers = { { kind = "memory", values = { REFRESH_TOKEN = "REFRESH01" } } },
        name = "refresh_token",
        exchange = { active = true, path = "auth/token" },
      }
      for k, v in pairs(extra or {}) do fopts[k] = v end
      local sdkopts = { feature = { secrets = fopts } }
      for k, v in pairs(sdkextra or {}) do sdkopts[k] = v end
      -- `active` is set here so an `exchange` override above can replace
      -- the whole block without dropping it.
      sdkopts.feature.secrets.active = true
      return secrets_client(w, sdkopts)
    end

    it("buys an access token with the resolved refresh token", function()
      local w = make_wire()
      local client = exchange_client(w)
      local res = client:direct({ path = "/probe" })
      assert.is_true(res.ok, tostring(res.err))

      assert.are.equal(1, #w.token(), "expected one token purchase")
      local t = w.token()[1]
      assert.are.equal("POST", t.method)
      assert.is_truthy(t.body:find('"refresh_token":"REFRESH01"', 1, true),
        "the refresh token must be sent as JSON: " .. tostring(t.body))
      assert_credential(w.api()[1].auth, "ACCESS01")
    end)

    it("a spent token is repurchased and the request retried once", function()
      local w = make_wire({ apistatus = { 401, 200 } })
      local client = exchange_client(w)
      local res = client:direct({ path = "/probe" })
      assert.is_true(res.ok, tostring(res.err))

      assert.are.equal(2, #w.api(), "expected the refused request and one retry")
      assert_credential(w.api()[1].auth, "ACCESS01")
      assert_credential(w.api()[2].auth, "ACCESS02")
      assert.are.equal(2, #w.token())
    end)

    it("a second refusal surfaces rather than spinning", function()
      local w = make_wire({ apistatus = { 401 } })
      local client = exchange_client(w)
      local res = client:direct({ path = "/probe" })
      assert.is_false(res.ok)
      assert.are.equal(401, res.status)
      assert.are.equal(2, #w.api(), "retries = 1 means exactly one retry")
    end)

    it("retries = 0 never repurchases", function()
      local w = make_wire({ apistatus = { 401 } })
      local client = exchange_client(w, { exchange = { active = true, retries = 0 } })
      local res = client:direct({ path = "/probe" })
      assert.is_false(res.ok)
      assert.are.equal(1, #w.api())
      assert.are.equal(1, #w.token(), "the initial purchase only")
    end)

    it("exchange.refresh seats first, as the explicit credential", function()
      local w = make_wire()
      local client = exchange_client(w, { exchange = { active = true, refresh = "EXPLICIT01" } })
      client:direct({ path = "/probe" })
      assert.is_truthy(w.token()[1].body:find('"refresh_token":"EXPLICIT01"', 1, true),
        tostring(w.token()[1].body))
    end)

    it("a held apikey is spent before anything is bought", function()
      local w = make_wire()
      local client = exchange_client(w, nil, { apikey = "HELD01" })
      client:direct({ path = "/probe" })
      assert.are.equal(0, #w.token(), "a held access token must be spent first")
      assert_credential(w.api()[1].auth, "HELD01")
    end)

    it("no refresh token anywhere is a refusal with the feature's message", function()
      local w = make_wire()
      local client = exchange_client(w, {
        providers = { { kind = "memory", values = {} } },
      })
      local res = client:direct({ path = "/probe" })
      assert.is_false(res.ok)
      assert.is_truthy(tostring(res.err):find("secrets: no refresh token", 1, true),
        tostring(res.err))
      assert.are.equal(0, #w.api())
    end)

    it("test mode buys nothing", function()
      -- A LIVE construction (so the feature is installed through extend),
      -- switched to test mode before the first request: the wrapper runs
      -- before the mode block in the base fetcher, so the purchase is what
      -- test mode sees - and it must answer the deterministic fake token
      -- without touching the token endpoint.
      local w = make_wire()
      local client = exchange_client(w)
      local sf = secrets_feature_of(client)
      client.mode = "test"

      local res = client:direct({ path = "/probe" })
      assert.is_false(res.ok, "test mode must block the request itself")
      assert.are.equal("test-access_token", sf:credential())
      assert.are.equal(0, #w.token(), "test mode must not reach the token endpoint")
    end)
  end)
end)
