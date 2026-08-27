# Univec SDK cost feature
#
# Cost tracking and spend budget. Uses BOTH seams, which is the point of the
# feature: money is spent per HTTP ATTEMPT (a retried call is charged again,
# because the upstream API charges it again), but it is owed by an OPERATION.
# So the transport wrap prices each attempt, and PreDone attributes the
# running total to `<entity>.<op>` and to the caller (`ctrl.actor`, the same
# actor the audit feature records).
#
# The price of an attempt comes from the first source that answers: a
# response header (`header` x `perUnit`), the rate table (`rates`, keyed
# `<entity>.<op>` / `<op>` / `*`), then the flat `unit`. A body figure
# (`path` x `perUnit`, e.g. "usage.total_tokens") is read at PreDone instead,
# from the already-parsed result. A body figure describes the whole call, so
# it REPLACES the per-attempt estimate rather than adding to it.
#
# `budget` caps total spend. With `onBudget` = "deny" a further operation is
# refused at PrePoint, before an endpoint is resolved and before anything
# reaches the network.
#
# ORDER MATTERS. Cost must sit INSIDE the cache, or a response served from
# cache is charged for money that was never spent. Aggregates live on
# `client._cost`; the per-operation accumulator lives on the ctx, the same
# place metrics keeps its start marker.

defmodule Univec.Feature.Cost do
  alias Voxgig.Struct, as: S
  alias Univec.Helpers, as: H
  alias Univec.{Feature, Context}

  def new do
    f = Feature.base("cost")
    Feature.install(f, "init", fn ctx, opts -> init(f, ctx, opts) end)
    Feature.install(f, "PrePoint", fn ctx -> pre_point(f, ctx) end)
    Feature.install(f, "PreDone", fn ctx -> finish(f, ctx, true) end)
    Feature.install(f, "PreUnexpected", fn ctx -> finish(f, ctx, false) end)
    f
  end

  def init(f, ctx, options) do
    active = Feature.init_common(f, ctx, options)

    client = S.getprop(f, "client")
    opts = Feature.opts(f)
    lim = limit(opts)

    Feature.track_node(
      client,
      "_cost",
      S.jm([
        "currency", H.or_(S.getprop(opts, "currency"), "USD"),
        "total", S.jm(["calls", 0, "attempts", 0, "amount", 0, "reported", 0, "estimated", 0]),
        "ops", S.jm([]),
        "actors", S.jm([]),
        "budget", S.jm(["limit", lim, "spent", 0, "remaining", lim, "exceeded", false]),
        "last", nil
      ])
    )

    S.setprop(f, "seq", 0)

    if active do
      utility = S.getprop(ctx, "utility")
      inner = S.getprop(utility, "fetcher")
      S.setprop(utility, "fetcher", fn fctx, url, fd -> charge(f, fctx, url, fd, inner) end)
    end

    nil
  end

  # Budget gate. Runs before endpoint resolution, so a refused call costs
  # nothing at all.
  defp pre_point(f, ctx) do
    if not Feature.active?(f) do
      nil
    else
      # Mark the context as running through the pipeline, so charge knows a
      # PreDone is coming and does not commit the spend itself.
      pending = pending_for(ctx)
      S.setprop(pending, "piped", true)

      opts = Feature.opts(f)
      lim = limit(opts)
      cost = S.getprop(S.getprop(f, "client"), "_cost")
      total = S.getprop(cost, "total")

      cond do
        lim <= 0 ->
          nil

        S.getprop(total, "amount") < lim ->
          nil

        true ->
          S.setprop(S.getprop(cost, "budget"), "exceeded", true)

          if S.getprop(opts, "onBudget") != "deny" do
            nil
          else
            currency = S.getprop(cost, "currency")

            err =
              Context.make_error(
                ctx,
                "cost_budget",
                "Cost budget of " <>
                  to_string(lim) <>
                  " " <>
                  to_string(currency) <>
                  " is spent (" <>
                  to_string(S.getprop(total, "amount")) <>
                  " " <> to_string(currency) <> " used)"
              )

            # Short-circuit endpoint resolution; the pipeline surfaces this error.
            S.setprop(S.getprop(ctx, "out"), "point", err)
            err
          end
      end
    end
  end

  # A failing transport still costs an attempt. Without this, a run of
  # connection-level failures under `retry` (which retries on an error) would
  # be charged nothing at all, and an onBudget = "deny" ceiling could never
  # stop it.
  defp charge(f, ctx, url, fetchdef, inner) do
    {res, err, raised} =
      try do
        {r, e} = inner.(ctx, url, fetchdef)
        {r, e, nil}
      rescue
        e -> {nil, nil, e}
      end

    opts = Feature.opts(f)
    {amount, source} = price(f, ctx, if(raised != nil, do: nil, else: res))

    cost = S.getprop(S.getprop(f, "client"), "_cost")
    total = S.getprop(cost, "total")

    pending = pending_for(ctx)

    # Accumulated here, committed once at PreDone. Adding each attempt to the
    # running total and then subtracting it again when a body figure
    # supersedes it loses precision to catastrophic cancellation
    # (5 + (0.01 - 5) is not 0.01 in binary floating point).
    #
    # Reported and estimated are kept apart per ATTEMPT, not per operation: a
    # 503 priced from the rate table followed by a 200 carrying the cost
    # header is part estimate, part reported, and collapsing both into the
    # final attempt's category would corrupt the split.
    S.setprop(pending, "attempts", S.getprop(pending, "attempts") + 1)
    S.setprop(pending, "amount", S.getprop(pending, "amount") + amount)

    bucket = if source == "header" or source == "body", do: "reported", else: "estimated"
    S.setprop(pending, bucket, S.getprop(pending, bucket) + amount)
    S.setprop(pending, "source", source)

    S.setprop(total, "attempts", S.getprop(total, "attempts") + 1)

    # direct() and graphql() reach the transport without dispatching any
    # pipeline hooks - no PrePoint to gate on, and no PreDone to commit. Their
    # spend is committed here instead, or it would never be counted and could
    # run past an onBudget = "deny" ceiling indefinitely. `piped` is set by
    # PrePoint, so its absence is the signal.
    if S.getprop(pending, "piped") != true do
      commit(f, ctx, pending, "_", "direct", opts)
      S.delprop(ctx, "_cost_pending")
    end

    if raised != nil, do: raise(raised), else: {res, err}
  end

  defp pending_for(ctx) do
    pending = S.getprop(ctx, "_cost_pending")

    if pending == nil do
      p =
        S.jm([
          "attempts", 0,
          "amount", 0,
          "reported", 0,
          "estimated", 0,
          "source", "none",
          "piped", false
        ])

      S.setprop(ctx, "_cost_pending", p)
      p
    else
      pending
    end
  end

  # PreDone attributes the operation's spend; PreUnexpected commits a FAILED
  # operation's, since PreDone never runs when the pipeline raises. Whichever
  # fires first consumes the pending entry, so it commits exactly once.
  defp finish(f, ctx, done) do
    if not Feature.active?(f) do
      nil
    else
      pending = S.getprop(ctx, "_cost_pending")

      cond do
        pending == nil ->
          nil

        # A FAILED operation that made no attempt never reached the network:
        # PrePoint creates the pending entry to mark the context as piped, and
        # then the budget gate refuses the call (rbac, or an unresolvable
        # endpoint, short-circuits just as early). Committing it would count a
        # call that never happened and file a zero-amount record as `last`.
        #
        # A SUCCEEDED operation that made no attempt is the opposite case: it
        # was served from the cache. That is a real call, and the fact that it
        # cost nothing is the whole point of ordering cost inside the cache.
        not done and S.getprop(pending, "attempts") == 0 ->
          S.delprop(ctx, "_cost_pending")
          nil

        true ->
          S.delprop(ctx, "_cost_pending")
          commit(f, ctx, pending, entity_of(ctx), opname_of(ctx), Feature.opts(f))
      end
    end
  end

  # Commit one operation's spend: totals, budget, per-op and per-actor
  # attribution, and the record. Shared by finish and the raw-request path in
  # charge, which has no PreDone to reach.
  defp commit(f, ctx, pending, entity, opname, opts) do
    cost = S.getprop(S.getprop(f, "client"), "_cost")
    total = S.getprop(cost, "total")

    # A body figure prices the whole call, so it replaces the per-attempt
    # estimate rather than adding to it - and, being server-stated, the whole
    # amount counts as reported.
    body = body_amount(ctx, opts)

    {amount, reported, estimated, source} =
      if body == nil do
        {S.getprop(pending, "amount"), S.getprop(pending, "reported"),
         S.getprop(pending, "estimated"), S.getprop(pending, "source")}
      else
        {body, body, 0, "body"}
      end

    spend(cost, amount, reported, estimated)

    ctrl = S.getprop(ctx, "ctrl")
    actor = if ctrl != nil, do: S.getprop(ctrl, "actor"), else: nil
    actor = if actor == nil, do: S.getprop(opts, "actor"), else: actor
    actor = if actor == nil, do: "anonymous", else: actor

    S.setprop(total, "calls", S.getprop(total, "calls") + 1)
    bump(S.getprop(cost, "ops"), entity <> "." <> opname, amount)
    bump(S.getprop(cost, "actors"), to_string(actor), amount)

    seq = H.or_(S.getprop(f, "seq"), 0) + 1
    S.setprop(f, "seq", seq)

    record =
      S.jm([
        "seq", seq,
        "entity", entity,
        "op", opname,
        "actor", actor,
        "amount", amount,
        "currency", S.getprop(cost, "currency"),
        "source", source,
        "attempts", S.getprop(pending, "attempts")
      ])

    S.setprop(cost, "last", record)

    sink = S.getprop(opts, "sink")

    if S.isfunc(sink) do
      # A sink must never break the call it is reporting on.
      try do
        sink.(record)
      rescue
        _ -> nil
      end
    end

    nil
  end

  # Price one attempt: a reported header figure, else the rate table, else the
  # flat unit.
  defp price(f, ctx, res) do
    opts = Feature.opts(f)
    header = S.getprop(opts, "header")

    hv =
      if is_binary(header) and header != "" do
        header_num(res, header)
      else
        nil
      end

    cond do
      hv != nil ->
        {hv * per_unit(opts), "header"}

      true ->
        rate = rate_for(ctx, opts)
        unit = S.getprop(opts, "unit")

        cond do
          rate != nil -> {rate, "table"}
          is_number(unit) and unit != 0 -> {unit, "unit"}
          true -> {0, "none"}
        end
    end
  end

  # The rate table uses the same lookup grammar as rbac's rules:
  # `<entity>.<op>`, then `<op>`, then `*`.
  defp rate_for(ctx, opts) do
    rates = S.getprop(opts, "rates")
    rates = if S.ismap(rates), do: rates, else: S.jm([])

    entity = entity_of(ctx)
    opname = opname_of(ctx)

    Enum.find_value([entity <> "." <> opname, opname, "*"], fn key ->
      v = S.getprop(rates, key)
      if is_number(v) and not is_boolean(v), do: v
    end)
  end

  # A usage figure from the parsed result body, priced by perUnit. Read here,
  # not at the transport seam, because the body is consumed once.
  defp body_amount(ctx, opts) do
    path = S.getprop(opts, "path")
    result = S.getprop(ctx, "result")
    body = if result != nil, do: S.getprop(result, "body"), else: nil

    if not is_binary(path) or path == "" or not S.ismap(body) do
      nil
    else
      v = S.getpath(body, path)
      if is_number(v) and not is_boolean(v), do: v * per_unit(opts), else: nil
    end
  end

  defp spend(cost, amount, reported, estimated) do
    total = S.getprop(cost, "total")
    S.setprop(total, "amount", S.getprop(total, "amount") + amount)
    S.setprop(total, "reported", S.getprop(total, "reported") + reported)
    S.setprop(total, "estimated", S.getprop(total, "estimated") + estimated)

    budget = S.getprop(cost, "budget")
    lim = S.getprop(budget, "limit")
    spent = S.getprop(total, "amount")
    S.setprop(budget, "spent", spent)

    if lim > 0 do
      S.setprop(budget, "remaining", max(0, lim - spent))
      if spent >= lim, do: S.setprop(budget, "exceeded", true)
    else
      S.setprop(budget, "remaining", 0)
    end

    nil
  end

  defp bump(bucket, key, amount) do
    b = S.getprop(bucket, key)

    b =
      if b == nil do
        nb = S.jm(["calls", 0, "amount", 0])
        S.setprop(bucket, key, nb)
        nb
      else
        b
      end

    S.setprop(b, "calls", S.getprop(b, "calls") + 1)
    S.setprop(b, "amount", S.getprop(b, "amount") + amount)
    nil
  end

  # HTTP header names are case-insensitive and a custom transport keeps
  # conventional casing ("X-Request-Cost"), so header_get scans rather than
  # indexes.
  defp header_num(res, name) do
    headers = if S.ismap(res), do: S.getprop(res, "headers"), else: nil

    if not S.ismap(headers) do
      nil
    else
      v = Feature.header_get(headers, name)

      cond do
        is_number(v) and not is_boolean(v) -> v
        is_binary(v) -> parse_num(v)
        true -> nil
      end
    end
  end

  defp parse_num(s) do
    case Float.parse(String.trim(s)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp entity_of(ctx) do
    name = Context.entity_name(S.getprop(ctx, "entity"))
    name = if name == "_", do: "", else: name

    if name == "" do
      op = S.getprop(ctx, "op")
      oe = if op != nil, do: S.getprop(op, "entity"), else: nil
      if is_binary(oe) and oe != "", do: oe, else: "_"
    else
      name
    end
  end

  defp opname_of(ctx) do
    op = S.getprop(ctx, "op")
    nm = if op != nil, do: S.getprop(op, "name"), else: nil
    if is_binary(nm) and nm != "", do: nm, else: "_"
  end

  defp per_unit(opts) do
    p = S.getprop(opts, "perUnit")
    if is_number(p) and not is_boolean(p), do: p, else: 0
  end

  defp limit(opts) do
    b = S.getprop(opts, "budget")
    if is_number(b) and not is_boolean(b), do: b, else: 0
  end
end
