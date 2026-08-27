# Univec SDK netsim feature
#
# Network behaviour simulation. Wraps the active transport (the live
# fetch or the `test` feature's in-memory mock) and injects realistic
# network conditions so offline unit tests can exercise slowness,
# transient failures, rate limiting and outages deterministically.
#
# Every injection mode is counter-driven (per client instance) so tests
# are reproducible without mocking timers. `failRate` adds optional
# pseudo-random failures via a seeded LCG for coverage-style testing.

defmodule Univec.Feature.Netsim do
  alias Voxgig.Struct, as: S
  alias Univec.Helpers, as: H
  alias Univec.{Feature, Context}

  def new do
    f = Feature.base("netsim")
    S.setprop(f, "calls", 0)
    S.setprop(f, "seed", 1)
    Feature.install(f, "init", fn ctx, opts -> init(f, ctx, opts) end)
    f
  end

  def init(f, ctx, options) do
    active = Feature.init_common(f, ctx, options)

    seed_opt = S.getprop(Feature.opts(f), "seed")

    seed =
      if is_number(seed_opt) and not is_boolean(seed_opt) and trunc(seed_opt) != 0 do
        trunc(seed_opt)
      else
        1
      end

    S.setprop(f, "seed", seed)

    if active do
      utility = S.getprop(ctx, "utility")
      inner = S.getprop(utility, "fetcher")

      S.setprop(utility, "fetcher", fn fctx, fullurl, fetchdef ->
        simulate(f, fctx, fullurl, fetchdef, inner)
      end)
    end

    nil
  end

  defp simulate(f, ctx, url, fetchdef, inner) do
    opts = Feature.opts(f)
    call = S.getprop(f, "calls") + 1
    S.setprop(f, "calls", call)

    # Record the simulated conditions for test/debug inspection.
    applied = S.jm([])

    cond do
      # Total outage: every call fails at the transport level.
      S.getprop(opts, "offline") == true ->
        Feature.sleep(f, pick_latency(f))
        S.setprop(applied, "offline", true)
        track(f, ctx, applied)

        {nil,
         Context.make_error(
           ctx,
           "netsim_offline",
           "Simulated network offline (URL was: \"" <> url <> "\")"
         )}

      # Connection-level errors for the first N calls (e.g. ECONNRESET).
      call <= int_or0(S.getprop(opts, "errorTimes")) ->
        Feature.sleep(f, pick_latency(f))
        S.setprop(applied, "error", true)
        track(f, ctx, applied)

        {nil,
         Context.make_error(
           ctx,
           "netsim_conn",
           "Simulated connection error (call " <> Integer.to_string(call) <> ")"
         )}

      # Rate-limit responses (HTTP 429 + Retry-After) for the first N calls.
      call <= int_or0(S.getprop(opts, "rateLimitTimes")) ->
        Feature.sleep(f, pick_latency(f))
        S.setprop(applied, "rateLimited", true)
        track(f, ctx, applied)

        ra = S.getprop(opts, "retryAfter")
        ra = if ra == nil, do: 0, else: ra

        ra_str =
          cond do
            is_binary(ra) -> ra
            is_number(ra) -> to_string(ra)
            true -> S.stringify(ra)
          end

        respond(ctx, 429, nil,
          S.jm(["statusText", "Too Many Requests", "headers", S.jm(["retry-after", ra_str])]))

      # Retryable failure status for the first N calls, or every Nth call.
      true ->
        fs = S.getprop(opts, "failStatus")
        fail_status = if fs == nil, do: 503, else: fs
        fail_every = int_or0(S.getprop(opts, "failEvery"))
        fr = S.getprop(opts, "failRate")
        fail_rate = if pytrue?(fr), do: fr, else: 0
        fail_by_count = call <= int_or0(S.getprop(opts, "failTimes"))
        fail_by_every = fail_every > 0 and rem(call, fail_every) == 0
        fail_by_rate = fail_rate > 0 and rand(f) < fail_rate

        if fail_by_count or fail_by_every or fail_by_rate do
          Feature.sleep(f, pick_latency(f))
          S.setprop(applied, "failStatus", fail_status)
          track(f, ctx, applied)
          respond(ctx, fail_status, nil, S.jm(["statusText", "Simulated Failure"]))
        else
          # Otherwise: apply latency then delegate to the real transport.
          latency = pick_latency(f)
          S.setprop(applied, "latency", latency)
          track(f, ctx, applied)
          Feature.sleep(f, latency)
          inner.(ctx, url, fetchdef)
        end
    end
  end

  # Latency in ms: a fixed number, or a uniform sample from {min,max}.
  defp pick_latency(f) do
    latency = S.getprop(Feature.opts(f), "latency")

    cond do
      latency == nil ->
        0

      is_number(latency) and not is_boolean(latency) ->
        if latency < 0, do: 0, else: latency

      not S.ismap(latency) ->
        0

      true ->
        mn = int_or0(S.getprop(latency, "min"))
        maxv = S.getprop(latency, "max")
        mx = if maxv == nil, do: mn, else: int_or0(maxv)
        if mx <= mn, do: mn, else: mn + trunc(rand(f) * (mx - mn))
    end
  end

  # Deterministic 0..1 pseudo-random via a linear congruential generator.
  defp rand(f) do
    seed = Bitwise.band(S.getprop(f, "seed") * 1103515245 + 12345, 0x7FFFFFFF)
    S.setprop(f, "seed", seed)
    seed / 0x7FFFFFFF
  end

  defp track(f, ctx, applied) do
    client = S.getprop(f, "client")
    t = Feature.track_node(client, "_netsim", S.jm(["calls", 0, "applied", S.jt([])]))
    S.setprop(t, "calls", S.getprop(t, "calls") + 1)
    Feature.list_push(S.getprop(t, "applied"), applied)

    ctrl = S.getprop(ctx, "ctrl")
    explain = if ctrl != nil, do: S.getprop(ctrl, "explain"), else: nil
    if S.ismap(explain), do: S.setprop(explain, "netsim", t)
    nil
  end

  # Build a transport-shaped response (matching the test feature's mock)
  # with a lower-cased header map the result pipeline understands.
  defp respond(_ctx, status, data, extra) do
    out =
      S.jm([
        "status", status,
        "statusText", "OK",
        "json", fn -> data end,
        "body", "not-used"
      ])

    if S.ismap(extra) do
      Enum.each(H.entries(extra), fn {k, v} -> S.setprop(out, k, v) end)
    end

    headers = S.getprop(out, "headers")
    headers = if S.ismap(headers), do: headers, else: S.jm([])

    lower = S.jm([])
    Enum.each(H.entries(headers), fn {k, v} -> S.setprop(lower, String.downcase(to_string(k)), v) end)
    S.setprop(out, "headers", lower)

    {out, nil}
  end

  # Mirrors Python `int(x or 0)`: falsey -> 0, then integer-truncate.
  defp int_or0(v) do
    cond do
      is_integer(v) -> v
      is_number(v) -> trunc(v)
      is_binary(v) -> (case Integer.parse(v) do
                         {n, _} -> n
                         _ -> 0
                       end)
      true -> 0
    end
  end

  # Python truthiness (nil / false / "" / 0 are falsey).
  defp pytrue?(v), do: not (v == nil or v == false or v == "" or v == 0)
end
