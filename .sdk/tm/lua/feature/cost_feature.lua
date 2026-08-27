-- Univec SDK cost feature
--
-- Cost tracking and spend budget. Uses BOTH seams, which is the point of
-- the feature: money is spent per HTTP ATTEMPT (a retried call is charged
-- again, because the upstream API charges it again), but it is owed by an
-- OPERATION. So the transport wrap prices each attempt, and PreDone
-- attributes the running total to `<entity>.<op>` and to the caller
-- (`ctrl.actor`, the same actor the audit feature records).
--
-- The price of an attempt comes from the first source that answers:
-- a response header (`header` x `perUnit`), the rate table (`rates`, keyed
-- '<entity>.<op>' / '<op>' / '*'), then the flat `unit`. A body figure
-- (`path` x `perUnit`, e.g. "usage.total_tokens") is read at PreDone
-- instead, from the already-parsed result. A body figure describes the
-- whole call, so it REPLACES the per-attempt estimate rather than adding
-- to it.
--
-- `budget` caps total spend. With `onBudget` = "deny" a further operation
-- is refused at PrePoint, before an endpoint is resolved and before
-- anything reaches the network.
--
-- ORDER MATTERS. Cost must sit INSIDE the cache, or a response served
-- from cache is charged for money that was never spent. The default (map)
-- order puts cache innermost and cost outside it, so activate them in
-- array form with cost first.

local BaseFeature = require("feature.base_feature")
local vs = require("utility.struct.struct")

local CostFeature = {}
CostFeature.__index = CostFeature
setmetatable(CostFeature, { __index = BaseFeature })


-- Case-insensitive header lookup on a plain header table. HTTP header
-- names are case-insensitive and a custom transport keeps conventional
-- casing ("X-Request-Cost"), so scan rather than index.
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


function CostFeature.new()
  local self = setmetatable(BaseFeature.new(), CostFeature)
  self.version = "0.0.1"
  self.name = "cost"
  self.active = true
  self.client = nil
  self.options = nil
  -- Weak keys: an abandoned context must not leak its accumulator.
  self.pending = setmetatable({}, { __mode = "k" })
  self.seq = 0
  return self
end


function CostFeature:init(ctx, options)
  self.client = ctx.client
  self.options = options or {}

  if options["active"] == true then
    self.active = true
  else
    self.active = false
  end

  self.pending = setmetatable({}, { __mode = "k" })
  self.seq = 0

  local limit = self:_limit()
  local client = self.client
  if client._cost == nil then
    client._cost = {
      currency = self.options["currency"] or "USD",
      total = { calls = 0, attempts = 0, amount = 0, reported = 0, estimated = 0 },
      ops = {},
      actors = {},
      budget = { limit = limit, spent = 0, remaining = limit, exceeded = false },
      last = nil,
    }
  end

  if not self.active then
    return
  end

  local cost_self = self
  local utility = ctx.utility
  local inner = utility.fetcher

  utility.fetcher = function(fctx, fullurl, fetchdef)
    return cost_self:_charge(fctx, fullurl, fetchdef, inner)
  end
end


-- Budget gate. Runs before endpoint resolution, so a refused call costs
-- nothing at all.
function CostFeature:PrePoint(ctx)
  if not self.active then
    return
  end

  -- Mark the context as running through the pipeline, so _charge knows a
  -- PreDone is coming and does not commit the spend itself.
  local pending = self.pending[ctx]
  if pending == nil then
    pending = self:_new_pending()
    self.pending[ctx] = pending
  end
  pending.piped = true

  local limit = self:_limit()
  if limit <= 0 then
    return
  end

  local cost = self.client._cost
  if cost.total.amount < limit then
    return
  end

  cost.budget.exceeded = true

  if self.options["onBudget"] ~= "deny" then
    return
  end

  local err = ctx:make_error("cost_budget",
    "Cost budget of " .. tostring(limit) .. " " .. cost.currency ..
    " is spent (" .. tostring(cost.total.amount) .. " " .. cost.currency .. " used)")
  -- Short-circuit endpoint resolution; the pipeline surfaces this error.
  ctx.out["point"] = err
  return err
end


function CostFeature:_charge(ctx, fullurl, fetchdef, inner)
  -- A failing transport still costs an attempt. Without this, a run of
  -- connection-level failures under `retry` (which retries on an error)
  -- would be charged nothing at all, and an onBudget = "deny" ceiling
  -- could never stop it.
  local res, err = inner(ctx, fullurl, fetchdef)

  local amount, source = self:_price(ctx, res)
  local cost = self.client._cost

  local pending = self.pending[ctx]
  if pending == nil then
    pending = self:_new_pending()
    self.pending[ctx] = pending
  end

  pending.attempts = pending.attempts + 1

  -- Accumulated here, committed once at PreDone. Adding each attempt to
  -- the running total and then subtracting it again when a body figure
  -- supersedes it loses precision to catastrophic cancellation
  -- (5 + (0.01 - 5) is not 0.01 in binary floating point).
  --
  -- Reported and estimated are kept apart per ATTEMPT, not per operation:
  -- a 503 priced from the rate table followed by a 200 carrying the cost
  -- header is part estimate, part reported, and collapsing both into the
  -- final attempt's category would corrupt the split.
  pending.amount = pending.amount + amount
  if source == "header" or source == "body" then
    pending.reported = pending.reported + amount
  else
    pending.estimated = pending.estimated + amount
  end
  pending.source = source

  cost.total.attempts = cost.total.attempts + 1

  -- direct() and graphql() reach the transport without dispatching any
  -- pipeline hooks - no PrePoint to gate on, and no PreDone to commit.
  -- Their spend is committed here instead, or it would never be counted
  -- and could run past an onBudget = "deny" ceiling indefinitely. `piped`
  -- is set by PrePoint, so its absence is the signal.
  if not pending.piped then
    self:_commit(ctx, pending, "_", "direct")
    self.pending[ctx] = nil
  end

  return res, err
end


function CostFeature:_new_pending()
  return {
    attempts = 0,
    amount = 0,
    reported = 0,
    estimated = 0,
    source = "none",
    piped = false,
  }
end


-- Attribute the operation's spend once the call is finished.
function CostFeature:PreDone(ctx)
  self:_finish(ctx, true)
end


-- A failed operation still spent the money. When the pipeline errors,
-- PreDone never runs, so without this the attempts are counted and the
-- spend is not, and a budget could never see the cost of a failed call.
-- Whichever hook fires first consumes the pending entry, so it commits
-- exactly once.
function CostFeature:PreUnexpected(ctx)
  self:_finish(ctx, false)
end


function CostFeature:_finish(ctx, done)
  if not self.active then
    return
  end
  local pending = self.pending[ctx]
  if pending == nil then
    return
  end
  self.pending[ctx] = nil

  -- A FAILED operation that made no attempt never reached the network:
  -- PrePoint creates the pending entry to mark the context as piped, and
  -- then the budget gate refuses the call (rbac, or an unresolvable
  -- endpoint, short-circuits just as early). Committing it would count a
  -- call that never happened and file a zero-amount record as `last`.
  --
  -- A SUCCEEDED operation that made no attempt is the opposite case: it
  -- was served from the cache. That is a real call, and the fact that it
  -- cost nothing is the whole point of ordering cost inside the cache.
  if not done and pending.attempts == 0 then
    return
  end

  local entity = "_"
  local opname = "_"
  if ctx.op ~= nil then
    if type(ctx.op.entity) == "string" and ctx.op.entity ~= "" then
      entity = ctx.op.entity
    end
    if type(ctx.op.name) == "string" and ctx.op.name ~= "" then
      opname = ctx.op.name
    end
  end

  self:_commit(ctx, pending, entity, opname)
end


-- Commit one operation's spend: totals, budget, per-op and per-actor
-- attribution, and the record. Shared by _finish and the raw-request path
-- in _charge, which has no PreDone to reach.
function CostFeature:_commit(ctx, pending, entity, opname)
  local cost = self.client._cost

  local amount = pending.amount
  local reported = pending.reported
  local estimated = pending.estimated
  local source = pending.source

  -- A body figure prices the whole call, so it replaces the per-attempt
  -- estimate rather than adding to it - and, being server-stated, the
  -- whole amount counts as reported.
  local body = self:_body(ctx)
  if body ~= nil then
    amount = body
    reported = body
    estimated = 0
    source = "body"
  end

  self:_spend(cost, amount, reported, estimated)

  local actor = nil
  if ctx.ctrl ~= nil and ctx.ctrl.actor ~= nil then
    actor = ctx.ctrl.actor
  end
  if actor == nil then
    actor = self.options["actor"]
  end
  if actor == nil then
    actor = "anonymous"
  end

  cost.total.calls = cost.total.calls + 1
  self:_bump(cost.ops, entity .. "." .. opname, amount)
  self:_bump(cost.actors, actor, amount)

  self.seq = self.seq + 1
  local record = {
    seq = self.seq,
    entity = entity,
    op = opname,
    actor = actor,
    amount = amount,
    currency = cost.currency,
    source = source,
    attempts = pending.attempts,
  }
  cost.last = record

  local sink = self.options["sink"]
  if type(sink) == "function" then
    pcall(sink, record)
  end
end


-- Price one attempt: a reported header figure, else the rate table, else
-- the flat unit. Returns amount, source.
function CostFeature:_price(ctx, res)
  local header = self.options["header"]
  if type(header) == "string" and header ~= "" then
    local v = self:_header(res, header)
    if v ~= nil then
      return v * self:_per_unit(), "header"
    end
  end

  local rate = self:_rate(ctx)
  if rate ~= nil then
    return rate, "table"
  end

  local unit = self.options["unit"]
  if type(unit) == "number" and unit ~= 0 then
    return unit, "unit"
  end

  return 0, "none"
end


-- The rate table uses the same lookup grammar as rbac's rules:
-- '<entity>.<op>', then '<op>', then '*'.
function CostFeature:_rate(ctx)
  local rates = self.options["rates"] or {}

  local entity = ""
  if ctx.entity ~= nil then
    if type(ctx.entity.get_name) == "function" then
      entity = ctx.entity:get_name()
    elseif type(ctx.entity.name) == "string" then
      entity = ctx.entity.name
    end
  end
  if entity == "" and ctx.op ~= nil and type(ctx.op.entity) == "string" then
    entity = ctx.op.entity
  end

  local opname = ""
  if ctx.op ~= nil and type(ctx.op.name) == "string" then
    opname = ctx.op.name
  end

  if type(rates[entity .. "." .. opname]) == "number" then
    return rates[entity .. "." .. opname]
  end
  if type(rates[opname]) == "number" then
    return rates[opname]
  end
  if type(rates["*"]) == "number" then
    return rates["*"]
  end
  return nil
end


-- A usage figure from the parsed result body, priced by perUnit. Read
-- here, not at the transport seam, because the body is consumed once.
function CostFeature:_body(ctx)
  local path = self.options["path"]
  if type(path) ~= "string" or path == "" then
    return nil
  end
  if ctx.result == nil or type(ctx.result.body) ~= "table" then
    return nil
  end
  local v = vs.getpath(ctx.result.body, path)
  local n = tonumber(v)
  if n == nil then
    return nil
  end
  return n * self:_per_unit()
end


function CostFeature:_spend(cost, amount, reported, estimated)
  cost.total.amount = cost.total.amount + amount
  cost.total.reported = cost.total.reported + reported
  cost.total.estimated = cost.total.estimated + estimated

  local limit = cost.budget.limit
  cost.budget.spent = cost.total.amount
  if limit > 0 then
    cost.budget.remaining = math.max(0, limit - cost.total.amount)
    if cost.total.amount >= limit then
      cost.budget.exceeded = true
    end
  else
    cost.budget.remaining = 0
  end
end


function CostFeature:_bump(bucket, key, amount)
  local b = bucket[key]
  if b == nil then
    b = { calls = 0, amount = 0 }
    bucket[key] = b
  end
  b.calls = b.calls + 1
  b.amount = b.amount + amount
end


function CostFeature:_header(res, name)
  if res == nil then
    return nil
  end
  return tonumber(header_get(res["headers"], name))
end


function CostFeature:_per_unit()
  local p = self.options["perUnit"]
  if type(p) == "number" then
    return p
  end
  return 0
end


function CostFeature:_limit()
  local b = self.options["budget"]
  if type(b) == "number" then
    return b
  end
  return 0
end


return CostFeature
