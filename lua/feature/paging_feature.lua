-- Univec SDK paging feature
--
-- Pagination support for list operations. On the way out (PreRequest) it
-- stamps page/limit (or a cursor) into the request query; on the way back
-- (PreResult) it reads the server's pagination signals — a
-- `Link: <...>; rel="next"` header, `X-Page`/`X-Next-Page`/
-- `X-Total-Count` headers, or `next`/`cursor`/`nextCursor`/`hasMore`
-- fields in the body — and records them on `ctx.result.paging`. A
-- per-call `ctrl.paging` (cursor or page) wins over the option defaults,
-- so auto-iteration can advance the cursor/page and re-issue the list
-- call until `hasMore` is false. Parameter names (`pageParam`,
-- `limitParam`, `cursorParam`), `startPage` (default 1) and `limit` are
-- configurable.

local BaseFeature = require("feature.base_feature")
local vs = require("utility.struct.struct")

local PagingFeature = {}
PagingFeature.__index = PagingFeature
setmetatable(PagingFeature, { __index = BaseFeature })


-- Case-insensitive header lookup on a plain header table.
local function header_get(headers, name)
  if type(headers) ~= "table" then
    return nil
  end
  local lower = string.lower(name)
  for k, v in pairs(headers) do
    if type(k) == "string" and string.lower(k) == lower then
      return v
    end
  end
  return nil
end


function PagingFeature.new()
  local self = setmetatable(BaseFeature.new(), PagingFeature)
  self.version = "0.0.1"
  self.name = "paging"
  self.active = true
  self.client = nil
  self.options = nil
  return self
end


function PagingFeature:init(ctx, options)
  self.client = ctx.client
  self.options = options or {}

  if options["active"] == true then
    self.active = true
  else
    self.active = false
  end
end


function PagingFeature:PreRequest(ctx)
  if not self.active then
    return
  end
  if not self:_is_list(ctx) then
    return
  end
  local spec = ctx.spec
  if spec == nil then
    return
  end
  if spec.query == nil then
    spec.query = {}
  end

  local page_param = self.options["pageParam"] or "page"
  local limit_param = self.options["limitParam"] or "limit"
  local cursor_param = self.options["cursorParam"] or "cursor"

  -- A per-call cursor/page from ctrl takes priority (used by
  -- auto-iteration).
  local paging = {}
  if ctx.ctrl ~= nil and type(ctx.ctrl.paging) == "table" then
    paging = ctx.ctrl.paging
  end

  -- GraphQL paginates through operation VARIABLES, not the query string.
  -- This hook runs after make_spec, so spec.body already holds the
  -- { query, variables } envelope, and before make_fetch_def serialises it.
  if vs.getprop(ctx.point, "kind") == "graphql" then
    self:_graphql_pre_request(ctx, paging)
    return
  end

  if paging["cursor"] ~= nil then
    spec.query[cursor_param] = paging["cursor"]
  elseif spec.query[page_param] == nil then
    if paging["page"] ~= nil then
      spec.query[page_param] = paging["page"]
    else
      spec.query[page_param] = self.options["startPage"] or 1
    end
  end

  if self.options["limit"] ~= nil and spec.query[limit_param] == nil then
    spec.query[limit_param] = self.options["limit"]
  end
end


-- Relay pagination: the cursor is the `after` variable (or whatever the model
-- named it), and the page size is `first`.
function PagingFeature:_graphql_pre_request(ctx, paging)
  local body = ctx.spec.body
  if type(body) ~= "table" then
    return
  end

  local variables = body["variables"]
  if type(variables) ~= "table" then
    variables = {}
    body["variables"] = variables
  end

  local after_var = self.options["afterVar"] or "after"
  local first_var = self.options["firstVar"] or "first"

  -- Only bind variables the operation actually declares, or the server
  -- rejects the document.
  local declared = {}
  local varlist = vs.getpath(ctx.point, "graphql.vars")
  if type(varlist) == "table" then
    for _, v in ipairs(varlist) do
      local name = vs.getprop(v, "name")
      if name ~= nil then
        declared[name] = true
      end
    end
  end

  if paging["cursor"] ~= nil and declared[after_var] then
    variables[after_var] = paging["cursor"]
  end

  if self.options["limit"] ~= nil and variables[first_var] == nil
    and declared[first_var] then
    variables[first_var] = self.options["limit"]
  end
end


function PagingFeature:PreResult(ctx)
  if not self.active then
    return
  end
  if not self:_is_list(ctx) then
    return
  end
  local result = ctx.result
  if result == nil then
    return
  end

  local headers = result.headers or {}
  local body = result.body

  local paging = {
    page = self:_num(header_get(headers, "x-page")),
    totalCount = self:_num(header_get(headers, "x-total-count")),
    nextPage = self:_num(header_get(headers, "x-next-page")),
    hasMore = false,
  }

  -- Link: <...>; rel="next"
  local link = header_get(headers, "link")
  if link ~= nil then
    local next_url = string.match(link,
      '<([^>]+)>%s*;%s*[Rr][Ee][Ll]="?[Nn][Ee][Xx][Tt]"?')
    if next_url ~= nil then
      paging.next = next_url
    end
  end

  -- Set when the response states hasMore outright, rather than leaving it to
  -- be inferred from the presence of a cursor.
  local explicit_more = false

  -- Relay connections carry the cursor in pageInfo, at the path the model
  -- recorded for this op.
  local page = vs.getpath(ctx.point, "graphql.page")
  if type(page) == "table" and type(body) == "table" then
    -- `connpath` locates the connection object inside the response envelope
    -- (data.<field>); the cursor/more paths are relative to it.
    local conn = body
    local connpath = page["connpath"]
    if type(connpath) == "string" and connpath ~= "" then
      local sub = vs.getpath(body, connpath)
      if sub ~= nil then
        conn = sub
      end
    end

    local cursorpath = page["cursor"]
    if type(cursorpath) == "string" and cursorpath ~= "" then
      local cursor = vs.getpath(conn, cursorpath)
      if cursor ~= nil then
        paging.cursor = cursor
      end
    end

    local morepath = page["more"]
    if type(morepath) == "string" and morepath ~= "" then
      local more = vs.getpath(conn, morepath)
      if type(more) == "boolean" then
        paging.hasMore = more
        explicit_more = true
      end
    end
  end

  -- Body-level cursors.
  if type(body) == "table" then
    if body["next"] ~= nil and paging.next == nil then
      paging.next = body["next"]
    end
    if body["cursor"] ~= nil then
      paging.cursor = body["cursor"]
    end
    if body["nextCursor"] ~= nil then
      paging.cursor = body["nextCursor"]
    end
    if type(body["hasMore"]) == "boolean" then
      paging.hasMore = body["hasMore"]
      explicit_more = true
    end
  end

  -- Cursor presence only INFERS another page. When the server stated the
  -- answer outright — relay's `hasNextPage: false`, or a body `hasMore` —
  -- that wins: a final page normally carries both an end cursor and
  -- hasNextPage false, and inferring from the cursor there would send the
  -- caller back for a page that does not exist, forever.
  if not explicit_more then
    paging.hasMore = paging.hasMore or
      paging.next ~= nil or paging.cursor ~= nil or paging.nextPage ~= nil
  end

  result.paging = paging

  local client = self.client
  client._paging = { last = paging }
end


function PagingFeature:_is_list(ctx)
  local ops = self.options["ops"] or { "list" }
  local opname = ctx.op ~= nil and ctx.op.name or nil
  for _, o in ipairs(ops) do
    if o == opname then
      return true
    end
  end
  return false
end


function PagingFeature:_num(v)
  if v == nil then
    return nil
  end
  return tonumber(v)
end


return PagingFeature
