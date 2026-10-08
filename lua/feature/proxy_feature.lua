-- Univec SDK proxy feature
--
-- Outbound HTTP(S) proxy support. Wraps the active transport and attaches
-- proxy routing to each request's fetch definition. The proxy target comes
-- from options (`url`) or, when `fromEnv` is set, the standard
-- HTTPS_PROXY / HTTP_PROXY / NO_PROXY environment variables (read via
-- `os.getenv`, injectable as `getenv` for tests). Constructing a concrete
-- transport agent is dependency-specific, so a factory may be supplied via
-- `options.agent`; when absent the request is annotated with
-- `fetchdef.proxy` for the transport to honour. Hosts matching `noProxy`
-- (exact or dot-suffix) bypass the proxy. Routed requests are counted on
-- `client._proxy`.

local BaseFeature = require("feature.base_feature")

local ProxyFeature = {}
ProxyFeature.__index = ProxyFeature
setmetatable(ProxyFeature, { __index = BaseFeature })


function ProxyFeature.new()
  local self = setmetatable(BaseFeature.new(), ProxyFeature)
  self.version = "0.0.1"
  self.name = "proxy"
  self.active = true
  self.client = nil
  self.options = nil
  self.url = nil
  self.no_proxy = {}
  self._ctx = nil
  return self
end


function ProxyFeature:init(ctx, options)
  self.client = ctx.client
  self.options = options or {}

  if options["active"] == true then
    self.active = true
  else
    self.active = false
  end

  if not self.active then
    return
  end

  local url = self.options["url"]
  if url == "" then
    url = nil
  end
  local no_proxy = self.options["noProxy"]

  if self.options["fromEnv"] == true then
    local getenv = self.options["getenv"]
    if type(getenv) ~= "function" then
      getenv = os.getenv
    end
    url = url or getenv("HTTPS_PROXY") or getenv("https_proxy")
      or getenv("HTTP_PROXY") or getenv("http_proxy")
    if no_proxy == nil or (type(no_proxy) == "table" and next(no_proxy) == nil) then
      no_proxy = getenv("NO_PROXY") or getenv("no_proxy") or no_proxy
    end
  end

  self.url = url
  self._ctx = ctx

  -- A proxy URL may carry credentials as userinfo, from the option or the
  -- environment, and neither is under a sensitive key name.
  if type(url) == "string" then
    local userinfo = string.match(url, "^%a[%w+.-]*://([^@/]+)@")
    if userinfo ~= nil then
      for part in string.gmatch(userinfo, "[^:]+") do
        ctx.utility.clean_add(ctx, part)
        ctx.utility.clean_add(ctx, (string.gsub(part, "%%(%x%x)", function(hex)
          return string.char(tonumber(hex, 16))
        end)))
      end
    end
  end

  self.no_proxy = {}
  if type(no_proxy) == "string" then
    for part in string.gmatch(no_proxy, "[^,]+") do
      local trimmed = part:match("^%s*(.-)%s*$")
      if trimmed ~= "" then
        table.insert(self.no_proxy, trimmed)
      end
    end
  elseif type(no_proxy) == "table" then
    for _, np in ipairs(no_proxy) do
      if np ~= nil and np ~= "" then
        table.insert(self.no_proxy, np)
      end
    end
  end

  local proxy_self = self
  local utility = ctx.utility
  local inner = utility.fetcher

  utility.fetcher = function(fctx, fullurl, fetchdef)
    fetchdef = proxy_self:_route(fullurl, fetchdef)
    return inner(fctx, fullurl, fetchdef)
  end
end


function ProxyFeature:_route(fullurl, fetchdef)
  if self.url == nil or self:_bypass(fullurl) then
    return fetchdef
  end

  local out = {}
  if type(fetchdef) == "table" then
    for k, v in pairs(fetchdef) do
      out[k] = v
    end
  end
  out["proxy"] = self.url

  local agent = self.options["agent"]
  if type(agent) == "function" then
    -- Factory returns a transport-specific agent/dispatcher.
    local made = agent(self.url, fullurl)
    out["dispatcher"] = made
    out["agent"] = made
  end

  self:_track(fullurl)
  return out
end


function ProxyFeature:_bypass(fullurl)
  if #self.no_proxy == 0 then
    return false
  end
  local host = string.match(fullurl, "^%a[%w+.-]*://([^/:]+)") or fullurl
  for _, np in ipairs(self.no_proxy) do
    if np == "*" then
      return true
    end
    local suffix = np:gsub("^%.", "")
    if host == np or host:sub(-(#suffix + 1)) == "." .. suffix then
      return true
    end
  end
  return false
end


function ProxyFeature:_track(fullurl)
  local client = self.client
  if client._proxy == nil then
    local ctx = self._ctx
    local url = self.url
    if ctx ~= nil and type(url) == "string" then
      url = ctx.utility.clean(ctx, url)
    end
    client._proxy = { routed = 0, url = url }
  end
  client._proxy.routed = client._proxy.routed + 1
end


return ProxyFeature
