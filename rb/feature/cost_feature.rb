# Univec SDK cost feature
#
# Cost tracking and spend budget. Uses BOTH seams, which is the point of the
# feature: money is spent per HTTP ATTEMPT (a retried call is charged again,
# because the upstream API charges it again), but it is owed by an
# OPERATION. So the transport wrap prices each attempt, and PreDone
# attributes the running total to "<entity>.<op>" and to the caller (the
# per-call ctrl actor, the same actor the audit feature records).
#
# The price of an attempt comes from the first source that answers: a
# response header ("header" x "perUnit"), the rate table ("rates", keyed
# "<entity>.<op>" / "<op>" / "*"), then the flat "unit". A body figure
# ("path" x "perUnit", e.g. "usage.total_tokens") is read at PreDone
# instead, from the already-parsed result, and describes the whole call, so
# it REPLACES the per-attempt estimate rather than adding to it.
#
# "budget" caps total spend. With "onBudget" => "deny" a further operation
# is refused at PrePoint, before an endpoint is resolved and before anything
# reaches the network.
#
# ORDER MATTERS. Cost must sit INSIDE the cache, or a response served from
# cache is charged for money that was never spent. The default (map) order
# puts cache innermost and cost outside it, so activate them in list form
# with cost first.

require_relative 'base_feature'

class UnivecCostFeature < UnivecBaseFeature
  def initialize
    super
    @version = "0.0.1"
    @name = "cost"
    # Inactive until init (feature_init only fires init when active).
    @active = false
    @client = nil
    @options = {}
    @pending = {}
    @seq = 0
  end

  def init(ctx, options)
    @client = ctx.client
    @options = options.is_a?(Hash) ? options : {}
    @active = @options["active"] == true
    @pending = {}
    @seq = 0

    limit = _limit

    if @client.instance_variable_get(:@_cost).nil?
      @client.instance_variable_set(:@_cost, {
        "currency" => @options["currency"] || "USD",
        "total" => {
          "calls" => 0, "attempts" => 0,
          "amount" => 0, "reported" => 0, "estimated" => 0
        },
        "ops" => {},
        "actors" => {},
        "budget" => {
          "limit" => limit, "spent" => 0,
          "remaining" => limit, "exceeded" => false
        },
        "last" => nil,
      })
    end

    return unless @active

    feature = self
    utility = ctx.utility
    inner = utility.fetcher

    utility.fetcher = ->(fctx, fullurl, fetchdef) {
      feature.charge(fctx, fullurl, fetchdef, inner)
    }
  end

  # The budget gate. Runs before endpoint resolution, so a refused call
  # costs nothing at all.
  def PrePoint(ctx)
    return unless @active

    # Mark the context as running through the pipeline, so charge knows a
    # PreDone is coming and does not commit the spend itself.
    entry = @pending[ctx]
    if entry.nil?
      entry = _new_pending
      @pending[ctx] = entry
    end
    entry["piped"] = true

    limit = _limit
    return if limit <= 0

    cost = @client.instance_variable_get(:@_cost)
    return if cost.nil?
    return if cost["total"]["amount"] < limit

    cost["budget"]["exceeded"] = true

    return unless "deny" == @options["onBudget"]

    err = ctx.make_error("cost_budget",
      "Cost budget of #{_numstr(limit)} #{cost['currency']} is spent " \
      "(#{_numstr(cost['total']['amount'])} #{cost['currency']} used)")

    # Short-circuit endpoint resolution; the pipeline surfaces this error.
    ctx.out["point"] = err
    err
  end

  def charge(ctx, url, fetchdef, inner)
    # A rejecting transport still costs an attempt. Without this, a run of
    # connection-level failures under "retry" (which rescues and tries again)
    # would be charged nothing at all, and an onBudget "deny" ceiling could
    # never stop it.
    threw = nil
    begin
      res, err = inner.call(ctx, url, fetchdef)
    rescue StandardError => ex
      threw = ex
      res = nil
      err = ex
    end

    amount, source = _price(ctx, res)

    entry = @pending[ctx]
    if entry.nil?
      entry = _new_pending
      @pending[ctx] = entry
    end

    entry["attempts"] += 1

    # Accumulated here, committed once at PreDone. Adding each attempt to
    # the running total and then subtracting it again when a body figure
    # supersedes it loses precision to catastrophic cancellation.
    #
    # Reported and estimated are kept apart per ATTEMPT: a 503 priced from
    # the rate table followed by a 200 carrying the cost header is part
    # estimate, part reported, and collapsing both into the final attempt's
    # category would corrupt the split.
    entry["amount"] += amount
    entry[%w[header body].include?(source) ? "reported" : "estimated"] += amount
    entry["source"] = source

    cost = @client.instance_variable_get(:@_cost)
    cost["total"]["attempts"] += 1 unless cost.nil?

    # direct() and graphql() reach the transport without dispatching any
    # pipeline hooks, so there is no PrePoint to gate on and no PreDone to
    # commit. Their spend is committed here, or it would never be counted.
    # "piped" is set by PrePoint, so its absence is the signal.
    unless entry["piped"]
      _commit(ctx, entry, "_", "direct")
      @pending.delete(ctx)
    end

    raise threw unless threw.nil?

    return res, err
  end

  def _new_pending
    {
      "attempts" => 0, "amount" => 0,
      "reported" => 0, "estimated" => 0,
      "source" => "none", "piped" => false
    }
  end

  # Attribute the operation's spend once the call is finished.
  def PreDone(ctx)
    _finish(ctx, true)
  end

  # A failed operation still spent the money. When the pipeline raises,
  # PreDone never runs, so without this the attempts are counted and the spend
  # is not, and a budget could never see the cost of a failed call. Whichever
  # hook fires first consumes the pending entry, so it commits exactly once.
  def PreUnexpected(ctx)
    _finish(ctx, false)
  end

  def _finish(ctx, done)
    return unless @active
    return unless @pending.key?(ctx)
    entry = @pending.delete(ctx)

    # A FAILED operation that made no attempt never reached the network:
    # PrePoint creates the pending entry to mark the context as piped, and
    # then the budget gate refuses the call (rbac, or an unresolvable
    # endpoint, short-circuits just as early). Committing it would count a
    # call that never happened and file a zero-amount record as `last`.
    #
    # A SUCCEEDED operation that made no attempt is the opposite case: it was
    # served from the cache. That is a real call, and the fact that it cost
    # nothing is the whole point of ordering cost inside the cache.
    return if !done && 0 == entry["attempts"]

    entity = ctx.op && ctx.op.entity ? ctx.op.entity : "_"
    opname = ctx.op && ctx.op.name ? ctx.op.name : "_"

    _commit(ctx, entry, entity, opname)
  end

  # Commit one operation's spend: totals, budget, per-op and per-actor
  # attribution, and the record. Shared by _finish and the raw-request path in
  # charge, which has no PreDone to reach.
  def _commit(ctx, entry, entity, opname)
    cost = @client.instance_variable_get(:@_cost)
    return if cost.nil?

    amount = entry["amount"]
    reported = entry["reported"]
    estimated = entry["estimated"]
    source = entry["source"]

    # A body figure prices the whole call, so it replaces the per-attempt
    # estimate rather than adding to it, and being server-stated the whole
    # amount counts as reported.
    body = _body(ctx)
    unless body.nil?
      amount = body
      reported = body
      estimated = 0
      source = "body"
    end

    _spend(cost, amount, reported, estimated)

    actor = _actor(ctx)

    cost["total"]["calls"] += 1
    _bump(cost["ops"], "#{entity}.#{opname}", amount)
    _bump(cost["actors"], actor, amount)

    @seq += 1
    record = {
      "seq" => @seq,
      "entity" => entity,
      "op" => opname,
      "actor" => actor,
      "amount" => amount,
      "currency" => cost["currency"],
      "source" => source,
      "attempts" => entry["attempts"],
    }
    cost["last"] = record

    sink = @options["sink"]
    if sink.is_a?(Proc)
      begin
        sink.call(record)
      rescue StandardError
        # A failing sink must never take down the call.
      end
    end
  end

  # Price one attempt: a reported header figure, else the rate table, else
  # the flat unit.
  def _price(ctx, res)
    header = @options["header"]
    if header.is_a?(String) && !header.empty?
      val = _header(res, header)
      return [val * _per_unit, "header"] unless val.nil?
    end

    rate = _rate(ctx)
    return [rate, "table"] unless rate.nil?

    unit = @options["unit"]
    return [unit, "unit"] if unit.is_a?(Numeric) && unit != 0

    [0, "none"]
  end

  # The rate table uses the same lookup grammar as rbac's rules:
  # "<entity>.<op>", then "<op>", then "*".
  def _rate(ctx)
    rates = @options["rates"]
    return nil unless rates.is_a?(Hash)

    entity = if ctx.entity && ctx.entity.respond_to?(:name) && ctx.entity.name
               ctx.entity.name
             elsif ctx.op && ctx.op.entity
               ctx.op.entity
             else
               ""
             end
    opname = ctx.op && ctx.op.name ? ctx.op.name : ""

    ["#{entity}.#{opname}", opname, "*"].each do |key|
      val = rates[key]
      return val if val.is_a?(Numeric)
    end
    nil
  end

  # A usage figure from the parsed result body, priced by perUnit. Read
  # here, not at the transport seam, because the body is one-shot.
  def _body(ctx)
    path = @options["path"]
    return nil unless path.is_a?(String) && !path.empty?
    return nil if ctx.result.nil? || ctx.result.body.nil?

    val = VoxgigStruct.getpath(ctx.result.body, path)
    num = _num(val)
    return nil if num.nil?
    num * _per_unit
  end

  def _spend(cost, amount, reported, estimated)
    cost["total"]["amount"] += amount
    cost["total"]["reported"] += reported
    cost["total"]["estimated"] += estimated

    limit = cost["budget"]["limit"]
    cost["budget"]["spent"] = cost["total"]["amount"]
    if limit > 0
      cost["budget"]["remaining"] = [0, limit - cost["total"]["amount"]].max
      cost["budget"]["exceeded"] = true if cost["total"]["amount"] >= limit
    else
      cost["budget"]["remaining"] = 0
    end
  end

  def _bump(bucket, key, amount)
    entry = bucket[key]
    if entry.nil?
      entry = { "calls" => 0, "amount" => 0 }
      bucket[key] = entry
    end
    entry["calls"] += 1
    entry["amount"] += amount
  end

  def _header(res, name)
    return nil unless res.is_a?(Hash)
    headers = res["headers"]
    return nil unless headers.is_a?(Hash)
    lower = name.downcase
    headers.each do |key, val|
      return _num(val) if key.to_s.downcase == lower
    end
    nil
  end

  def _num(val)
    return val if val.is_a?(Numeric) && !val.is_a?(TrueClass) && !val.is_a?(FalseClass)
    if val.is_a?(String)
      begin
        return Float(val.strip)
      rescue ArgumentError, TypeError
        return nil
      end
    end
    nil
  end

  def _actor(ctx)
    if ctx.ctrl && ctx.ctrl.respond_to?(:actor) && !ctx.ctrl.actor.nil?
      return ctx.ctrl.actor
    end
    @options["actor"] || "anonymous"
  end

  def _per_unit
    per = @options["perUnit"]
    per.is_a?(Numeric) ? per : 0
  end

  def _limit
    budget = @options["budget"]
    budget.is_a?(Numeric) ? budget : 0
  end

  # Render a money amount without an exponent or trailing zeros.
  def _numstr(n)
    return n.to_s if n.is_a?(Integer)
    s = format("%.10f", n.to_f).sub(/0+\z/, "").sub(/\.\z/, "")
    s.empty? ? "0" : s
  end
end
