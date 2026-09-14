-- Univec SDK secrets feature
--
-- Secret access via a vendored @voxgig/sekreto provider chain, and the
-- access-token exchange some APIs require on top of it. The lua port of
-- tm/ts/src/feature/secrets/SecretsFeature.ts, seam for seam with the go
-- port (tm/go/feature/secrets_feature.go), whose structure this target
-- shares: a top-level feature/ container, synchronous hooks that cannot
-- fail an operation, and a transport that both raw paths cross.
--
-- The SDK's `apikey` option keeps exactly its old meaning: an explicit
-- credential given in code. This feature makes it ONE SOURCE among several
-- rather than the only one: when active, the apikey is resolved through a
-- sekreto chain in which the explicit option (when set) is the FIRST
-- provider - a `memory` store named `options` - so an explicit value always
-- wins, by sekreto's own first-hit rule rather than by special-case logic.
--
-- WHY THE TRANSPORT, NOT A HOOK. Every entity op runs feature_hook("PreSpec")
-- before make_spec builds the auth header, so a hook COULD resolve in time -
-- but utility/feature_hook.lua discards a hook's return value, so a PreSpec
-- hook can neither fail an operation nor be awaited, and `direct()` /
-- `graphql()` run no hooks at all. The transport wrapper installed in init
-- is the one seam every wire path crosses: entity ops (make_request), the
-- raw paths (_raw_request) and the exchange retries all come through it. It
-- resolves there, rewrites the authorization header prepare_auth built from
-- the options apikey, and - this is the point - REFUSES TO SEND while the
-- chain is broken.
--
-- MISS vs ERROR (sekreto's invariant): a provider MISS falls through - the
-- op proceeds, unauthenticated if nothing else supplies a credential. A
-- provider ERROR (unreachable vault, bad creds) must FAIL the op: a broken
-- vault never degrades into an unauthenticated request. The same gate holds
-- a construction failure: a `providers` entry that is not a provider or a
-- spec, or a kind this SDK was not generated with, is recorded at init and
-- every request is refused with sekreto's own message. Fail-closed at the
-- one seam every request must pass, and never a silently shortened chain.
--
-- THE RESOLVED CREDENTIAL IS FEATURE STATE, not an options write - go's
-- discipline, kept here for the same reason it is right there: the options
-- map is read raw on every request, and a feature that wrote into it would
-- be racing its own readers in a runtime with coroutines. The header the
-- wire sees is identical, because the wrapper builds it the way prepare_auth
-- does, from the same options.auth.prefix.
--
-- EXCHANGE: some APIs will not take a long-lived credential at all. What
-- the chain resolves is then a REFRESH token, which buys a short-lived
-- ACCESS token from a token endpoint (`exchange.path`, relative to
-- options.base); the access token is what every request carries, and when
-- a response status in `exchange.statuses` (401) says it is spent the
-- wrapper buys another and retries the same request once. Test mode buys
-- nothing and answers with a deterministic fake token.
--
-- PLUGIN KINDS. The four built-in kinds (env, memory, dotenv, file) come
-- with the vendored core; every other kind is a voxgig/plugin definition
-- the generated config_plugins module hands in, and only the groups the
-- model activated are in the tree at all. Those kinds reach
-- feature/secrets/sekreto/plugins/net.lua, which runs the compiled
-- transport helper (feature/secrets/native/sekreto-net) because Lua 5.4
-- has no sockets and no TLS - `make build` compiles it whenever a plugin
-- group is active, and never otherwise.

local vs = require("utility.struct.struct")
local json = require("dkjson")
local helpers = require("core.helpers")
local BaseFeature = require("feature.base_feature")
local sekreto = require("feature.secrets.sekreto")


local SecretsFeature = {}
SecretsFeature.__index = SecretsFeature
setmetatable(SecretsFeature, { __index = BaseFeature })


-- Sekreto's own wording for a chain entry that is neither a provider nor a
-- spec (the dynamic-list refusal in the ts and kotlin constructors). The
-- lua constructor cannot be handed a non-table at all - a number entry
-- raises a bare "attempt to index" from inside sekreto, and a nil HOLE in
-- the list ends `ipairs` early and silently SHORTENS the chain - so the
-- classification is done here, with the constructor's message, and the
-- transport gate refuses to send. A shortened chain is exactly the
-- fail-open the gate exists to prevent.
local NOTAPROVIDER = "sekreto: not a provider or a provider spec: "


local function optstr(map, key, dflt)
  local v = map ~= nil and map[key] or nil
  if type(v) == "string" and v ~= "" then
    return v
  end
  return dflt
end


local function optnum(map, key, dflt)
  local v = map ~= nil and map[key] or nil
  if type(v) == "number" then
    return math.floor(v)
  end
  return dflt
end


-- The plugin DEFINITIONS the model selected for this feature, emitted by
-- Config_lua into config_plugins.lua from the catalogue's active
-- `plugin.def` entries. Upstream sekreto's contract since the registry
-- was retired: a kind not passed in `plugins` is unknown to that Sekreto,
-- so the model's choice of plugin groups IS the SDK's provider vocabulary.
--
-- Only a genuine module-not-found is tolerated (this template run against
-- the raw tm/ tree, with no generated config beside it): anything else is
-- a plugin module that failed to LOAD, and that must reach the gate rather
-- than quietly leave the chain without a kind it was configured with.
local function feature_plugins(name)
  local ok, accessor = pcall(require, "config_plugins")
  if not ok then
    if type(accessor) == "string"
      and accessor:find("module 'config_plugins' not found", 1, true) ~= nil
    then
      return {}, nil
    end
    return nil, accessor
  end
  if type(accessor) == "function" then
    return accessor(name) or {}, nil
  end
  return {}, nil
end


function SecretsFeature.new()
  local self = setmetatable(BaseFeature.new(), SecretsFeature)
  self.version = "0.1.0"
  self.name = "secrets"
  self.active = true
  self.client = nil
  self.options = nil

  -- The LIVE options table (the root context's, which is client.options):
  -- read for `apikey` and for the `auth` suppression, never written.
  self._liveopts = nil

  self._secretname = "apikey"
  self._cache = true
  self._sek = nil

  -- Exchange state: nil config when off; the refresh credential the chain
  -- resolved.
  self._exchange = nil
  self._refresh = nil

  -- The RESOLVED credential (nil when none), the resolved flag the cache
  -- keeps, and the construction failure the transport gate refuses on.
  self._cred = nil
  self._resolved = false
  self._initerr = nil

  return self
end


-- init is sync by feature contract: build the chain, never look anything
-- up here.
function SecretsFeature:init(ctx, options)
  self.client = ctx.client
  self.options = options or {}
  self._liveopts = ctx.options or {}
  self.active = (self.options["active"] == true)

  if not self.active then
    return
  end

  self._secretname = optstr(self.options, "name", "apikey")
  self._cache = (self.options["cache"] ~= false)

  -- Exchange config, normalised once. Nil when off, so every later
  -- decision is a nil check.
  local xopts = helpers.to_map(self.options["exchange"])
  if xopts ~= nil and xopts["active"] == true then
    local statuses = {}
    if type(xopts["statuses"]) == "table" then
      for _, s in ipairs(xopts["statuses"]) do
        statuses[#statuses + 1] = math.floor(tonumber(s) or 0)
      end
    end
    if #statuses == 0 then
      statuses = { 401 }
    end
    self._exchange = {
      path = optstr(xopts, "path", "auth/token"),
      method = optstr(xopts, "method", "POST"),
      request = optstr(xopts, "request", "refresh_token"),
      response = optstr(xopts, "response", "access_token"),
      statuses = statuses,
      retries = optnum(xopts, "retries", 1),
    }
  end

  -- WRAP FIRST, before anything below can fail. The gate lives in the
  -- wrapper, so a chain that cannot be built must still find it installed
  -- - otherwise a construction failure would leave the ORIGINAL transport
  -- in place and every request would go out unauthenticated, which is the
  -- one outcome this feature exists to prevent. Wrapping whatever
  -- transport is current at init also means the exchange (when on) SEES
  -- responses, which is the only place expiry is ever discovered.
  local secrets_self = self
  local utility = ctx.utility
  local inner = utility.fetcher
  utility.fetcher = function(fctx, fullurl, fetchdef)
    return secrets_self:_transport(fctx, fullurl, fetchdef, inner)
  end

  -- The explicit credential, when set, is the first store in the chain.
  --
  -- WHICH option that is depends on the exchange. Without one, the secret
  -- being resolved IS the credential the transport sends, so `apikey` is
  -- it. With one, the secret is a REFRESH token and `apikey` means the
  -- opposite thing - an access token the caller already holds - so the
  -- explicit seat belongs to `exchange.refresh`, and apikey is left alone
  -- to serve as the starting access token (see _resolve_once).
  local explicit = nil
  if self._exchange == nil then
    explicit = self._liveopts["apikey"]
  elseif xopts ~= nil then
    explicit = xopts["refresh"]
  end

  local specs = {}

  if type(explicit) == "string" and explicit ~= "" then
    local ok, key = pcall(sekreto.envkey, self._secretname, "")
    if ok then
      specs[#specs + 1] = {
        kind = "memory",
        name = "options",
        values = { [key] = explicit },
      }
    else
      -- An invalid secret `name` is a misconfiguration, and sekreto's own
      -- message says which. Refused at the gate rather than skipped.
      self._initerr = key
    end
  end

  -- The chain, entry by entry. A table is handed to sekreto verbatim - a
  -- live provider (callable `lookup`, duck-typed) or a spec, and a spec
  -- naming a kind this SDK was not generated with is refused by sekreto's
  -- constructor with its own message. Anything else - a bare kind name
  -- ("hashicorp"), a number, a nil hole - is refused HERE (see
  -- NOTAPROVIDER); the list is walked to its highest integer key so a hole
  -- cannot end it early. The first refusal is the one reported.
  local given = self.options["providers"]
  if given ~= nil then
    if type(given) ~= "table" then
      self._initerr = self._initerr
        or sekreto.SekretoError(NOTAPROVIDER .. tostring(given))
    else
      local last = 0
      for k in pairs(given) do
        if math.type(k) == "integer" and k > last then
          last = k
        end
      end
      for i = 1, last do
        local entry = given[i]
        if type(entry) == "table" then
          specs[#specs + 1] = entry
        else
          self._initerr = self._initerr
            or sekreto.SekretoError(NOTAPROVIDER .. tostring(entry))
        end
      end
    end
  end

  local plugs, perr = feature_plugins(self.name)
  if perr ~= nil then
    self._initerr = self._initerr or perr
  end

  -- Construction contacts nothing: a provider opens nothing until its
  -- first lookup. A refusal here (unknown kind, a plugin kind not passed
  -- in, a spec the kind rejects) is kept for the gate: init cannot fail
  -- the construction the way ts's throwing init does, so the transport
  -- refuses to send instead, which keeps a misconfigured chain
  -- fail-closed rather than silently unauthenticated.
  local ok, sek = pcall(sekreto.sekreto, {
    providers = specs,
    plugins = plugs or {},
    cache = self._cache,
  })
  if not ok then
    self._initerr = self._initerr or sek
    return
  end
  self._sek = sek
end


-- The LIVE Sekreto instance, for callers who want arbitrary secrets or
-- redaction (the lua spelling of ts's public sekreto() accessor):
--
--   feature:sekreto():get("db.password")
--   feature:sekreto():redact(logline)
--
-- Never a clone: sekreto holds provider state that has to stay live to be
-- worth anything. Nil while the chain could not be built.
function SecretsFeature:sekreto()
  return self._sek
end


-- The resolved credential (nil when none) - the state the transport
-- injects. Tests and callers read it here rather than from the options
-- map, which this feature never mutates.
function SecretsFeature:credential()
  return self._cred
end


-- The construction failure the gate refuses on, or nil.
function SecretsFeature:init_error()
  return self._initerr
end


-- One resolution. A settled SUCCESS is kept only when caching is on
-- (`cache = false` means every request asks the chain again); a FAILURE
-- is never kept, so a transient vault outage does not poison the client
-- permanently - the next operation asks the chain again.
function SecretsFeature:_resolve()
  if self._initerr ~= nil then
    return self._initerr
  end

  if self._resolved and self._cache then
    return nil
  end

  local err = self:_resolve_once()
  if err ~= nil then
    self._resolved = false
    return err
  end

  self._resolved = true
  return nil
end


function SecretsFeature:_resolve_once()
  if self._sek == nil then
    return nil
  end

  -- Miss-vs-error: `tryget` answers nil for "no store has it" and RAISES
  -- for "a store could not answer" - only the miss falls through.
  local ok, found = pcall(self._sek.tryget, self._sek, self._secretname)
  if not ok then
    return found
  end

  if self._exchange == nil then
    -- A hit is the credential. An UNCACHED miss after an earlier hit is a
    -- revocation: the chain now says no provider has the secret, so the
    -- resolved value must not keep going out on the wire - nil RETRACTS
    -- it. (An explicit apikey OPTION is never lost here: it seats FIRST
    -- in the chain as a memory provider, so the chain HITS while one is
    -- set and the miss branch is unreachable.)
    self._cred = found
    return nil
  end

  -- Exchanging: what the chain resolved is the REFRESH token, kept for
  -- every later purchase. A miss is not fatal here - an explicit `apikey`
  -- may already hold a usable access token, and the API is what gets to
  -- say whether it does.
  self._refresh = found

  local apikey = self._cred
  if type(apikey) ~= "string" or apikey == "" then
    -- A starting access token supplied as the OPTION, read from the live
    -- options (no feature ever writes it).
    apikey = self._liveopts["apikey"]
    if type(apikey) == "string" and apikey ~= "" then
      self._cred = apikey
    end
  end
  if type(apikey) == "string" and apikey ~= "" then
    -- A starting access token was supplied. Spend it: if it is stale the
    -- API answers with an expiry status and the transport wrapper buys
    -- another, which is the same path expiry takes anyway.
    return nil
  end

  local _, err = self:_buy()
  return err
end


-- The transport wrapper: whatever transport was current at init, behind
-- the fail-closed gate.
function SecretsFeature:_transport(ctx, fullurl, fetchdef, inner)
  -- Fail-closed, at the ONE seam every wire path crosses. A construction
  -- failure or a provider ERROR refuses the request with sekreto's own
  -- message - never an unauthenticated send. resolve() is cached: a
  -- settled success is free, and with `cache = false` the chain is asked
  -- once per REQUEST, which is that option's meaning.
  local refused = self:_resolve()
  if refused ~= nil then
    return nil, ctx:make_error("secrets_refused", sekreto.errmessage(refused))
  end

  -- Inject the resolved credential into THIS request's header. The header
  -- was built by prepare_auth from the options apikey; the chain-resolved
  -- value lives in feature state instead (see _cred), so the wrapper
  -- writes it here - same construction, same suppression rule - and the
  -- shared options map stays untouched.
  local cred = self._cred
  if type(cred) == "string" and cred ~= "" then
    self:_reauth(fetchdef, cred)
  end

  if self._exchange == nil then
    return inner(ctx, fullurl, fetchdef)
  end

  return self:_with_refresh(ctx, fullurl, fetchdef, inner)
end


-- Buy a token and try the request again when the API says the current one
-- is spent. The retry rewrites the authorization header IN PLACE on the
-- fetchdef, because the header was built before this request left and it
-- carries the token that just failed.
function SecretsFeature:_with_refresh(ctx, fullurl, fetchdef, inner)
  -- A suppressed `auth` is the documented way to send NO credential, and
  -- prepare_auth honours it by removing the header. A refusal of a
  -- deliberately unauthenticated request is not an expired token and
  -- cannot be fixed by buying one - retrying would transmit exactly the
  -- credential the caller suppressed.
  if self._liveopts["auth"] == nil then
    return inner(ctx, fullurl, fetchdef)
  end

  local max = self._exchange.retries
  local attempt = 0

  while true do
    -- The credential THIS attempt goes out with, captured before it
    -- leaves: it is what tells a stale refusal apart from a fresh one.
    local used = self._cred

    local res, err = inner(ctx, fullurl, fetchdef)

    if err ~= nil or attempt >= max or not self:_spent(res) then
      return res, err
    end

    -- Another request may have bought a token while this one was in
    -- flight (a coroutine-driven caller): spend what is current before
    -- buying, because a second exchange for a token that is already fresh
    -- is wasted, and on a provider that invalidates the previous
    -- credential on issuance it breaks the first request's own retry.
    local current = self._cred
    local token = nil

    if type(current) == "string" and current ~= "" and current ~= used then
      token = current
    else
      local bought, berr = self:_buy()
      if berr ~= nil then
        -- The purchase failed: answer with the API's own refusal rather
        -- than this one. The caller asked for data, and the refusal is
        -- the more useful of the two - the exchange error is a symptom.
        return res, nil
      end
      token = bought
    end

    self:_reauth(fetchdef, token)

    attempt = attempt + 1
  end
end


function SecretsFeature:_spent(res)
  if type(res) ~= "table" then
    return false
  end
  local status = helpers.to_int(vs.getprop(res, "status"))
  for _, s in ipairs(self._exchange.statuses) do
    if s == status then
      return true
    end
  end
  return false
end


-- Write the credential into the request the way prepare_auth writes it.
function SecretsFeature:_reauth(fetchdef, token)
  local headers = helpers.to_map(type(fetchdef) == "table" and fetchdef["headers"] or nil)
  if headers == nil then
    return
  end

  -- Suppressed auth means NO header, the same answer prepare_auth gives.
  -- Lua cannot spell `auth: null` in the options a caller passes (a table
  -- stores no nil, and validate then fills the default), so the only
  -- expressible suppression is clearing `client.options.auth` after
  -- construction; this is the live table, so it is honoured here too.
  local auth = self._liveopts["auth"]
  if type(auth) ~= "table" then
    headers["authorization"] = nil
    return
  end

  local prefix = auth["prefix"]
  if type(prefix) ~= "string" then
    prefix = ""
  end

  if prefix == "" then
    headers["authorization"] = token
  else
    headers["authorization"] = prefix .. " " .. token
  end
end


-- Buy an access token with the refresh token.
function SecretsFeature:_buy()
  -- TEST MODE BUYS NOTHING. The test feature replaces the transport so no
  -- request leaves the process; an exchange here would be the one HTTP
  -- call it could not stop, and it would need a live token endpoint for a
  -- suite whose whole point is not needing one. A deterministic,
  -- obviously-fake token instead - the same answer make_options gives a
  -- required server variable, for the same reason.
  if self.client.mode ~= "live" then
    local token = "test-" .. self._exchange.response
    self._cred = token
    return token, nil
  end

  local token, err = self:_buy_once()
  if err ~= nil then
    return nil, err
  end

  self._cred = token
  return token, nil
end


-- The token-exchange transport of last resort: LuaSocket's http, answering
-- the same shape the system.fetch seam promises (status + json). It exists
-- so an exchange works with ordinary SDK options - requiring a custom
-- transport for the COMMON case would reject every live token purchase
-- before a request was made. Mirrors utility/fetcher.lua's own default
-- (which is a local there, not exported); like it, this is HTTP through
-- socket.http, and an https token endpoint needs luasec's ssl.https on the
-- package path, which the rockspec does not require.
local function raw_exchange_fetch(fullurl, fetchdef)
  local http_ok, http = pcall(require, "socket.http")
  local ltn12_ok, ltn12 = pcall(require, "ltn12")
  if not http_ok or not ltn12_ok then
    return nil, "HTTP library not available (install luasocket)"
  end

  local headers = {}
  for k, v in pairs(fetchdef["headers"] or {}) do
    if type(v) == "string" then
      headers[k] = v
    end
  end

  local body = fetchdef["body"]
  if type(body) ~= "string" then
    body = nil
  end
  if body ~= nil then
    headers["content-length"] = tostring(#body)
  end

  local chunks = {}
  local res, code = http.request({
    url = fullurl,
    method = fetchdef["method"] or "POST",
    headers = headers,
    source = body and ltn12.source.string(body) or nil,
    sink = ltn12.sink.table(chunks),
  })

  if not res then
    return nil, code
  end

  local raw = table.concat(chunks)

  return {
    status = code,
    json = function()
      if #raw == 0 then
        return nil
      end
      local decoded = json.decode(raw)
      return decoded
    end,
    body = raw,
  }, nil
end


function SecretsFeature:_buy_once()
  local x = self._exchange

  if type(self._refresh) ~= "string" or self._refresh == "" then
    return nil, sekreto.SekretoError(
      "secrets: no refresh token: the provider chain has no '" ..
      self._secretname .. "', and feature.secrets.exchange.refresh is unset")
  end

  local options = self.client:options_map()

  -- The token endpoint is RELATIVE to the base, which already carries
  -- whatever account or tenant segment the server URL declares.
  local base = vs.getprop(options, "base")
  if type(base) ~= "string" then
    base = ""
  end
  base = base:gsub("/+$", "")
  local url = base .. "/" .. (x.path:gsub("^/+", ""))

  -- Deliberately NOT the SDK transport. The transport is what this feature
  -- wraps, and sending the token request back through it would recurse on
  -- the first expiry - and would route the exchange through the test mock,
  -- which knows nothing about it. system.fetch, when the caller supplied
  -- one, is the raw seam beneath the transport and is honoured.
  local fetch = vs.getpath(options, "system.fetch")
  if type(fetch) ~= "function" then
    fetch = raw_exchange_fetch
  end

  -- The body is ENCODED, never concatenated: a refresh token (or a
  -- configured request-field name) carrying a quote, backslash or newline
  -- must arrive as that literal value, not as malformed JSON.
  local res, err = fetch(url, {
    method = x.method,
    headers = { ["content-type"] = "application/json" },
    body = json.encode({ [x.request] = self._refresh }),
  })

  if err ~= nil then
    return nil, sekreto.SekretoError(
      "secrets: token exchange failed: " .. tostring(err) .. " from " .. url)
  end

  local status = type(res) == "table" and helpers.to_int(vs.getprop(res, "status")) or -1
  if status < 200 or status >= 300 then
    return nil, sekreto.SekretoError(
      "secrets: token exchange failed: " .. tostring(status) .. " from " .. url)
  end

  local body = nil
  local jf = vs.getprop(res, "json")
  if type(jf) == "function" then
    local ok, decoded = pcall(jf)
    if ok then
      body = decoded
    end
  else
    body = vs.getprop(res, "body")
    if type(body) == "string" then
      body = json.decode(body)
    end
  end

  local token = type(body) == "table" and body[x.response] or nil

  if type(token) ~= "string" or token == "" then
    return nil, sekreto.SekretoError(
      "secrets: token exchange returned no '" .. x.response .. "' field from " .. url)
  end

  return token, nil
end


return SecretsFeature
