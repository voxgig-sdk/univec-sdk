# Univec SDK ratelimit feature
#
# Client-side rate limiting via a token bucket. Each request consumes a
# token; when the bucket is empty the request waits until the bucket refills
# at `rate` tokens per second (with capacity `burst`, default: `rate`). This
# keeps the client under a server's published quota rather than discovering
# it via 429s. The clock (`now`) and the wait (`sleep`) are injectable so the
# accounting can be tested deterministically without wall-clock timing.

defmodule Univec.Feature.Ratelimit do
  alias Voxgig.Struct, as: S
  alias Univec.Feature, as: F

  def new do
    f = F.base("ratelimit")
    F.install(f, "init", fn ctx, opts -> init(f, ctx, opts) end)
    f
  end

  def init(f, ctx, options) do
    active = F.init_common(f, ctx, options)

    if active do
      opts = F.opts(f)
      rate = por(S.getprop(opts, "rate"), 5)
      burst = case S.getprop(opts, "burst") do nil -> rate; v -> v end
      S.setprop(f, "tokens", burst)
      S.setprop(f, "last", F.now(f))

      utility = S.getprop(ctx, "utility")
      inner = S.getprop(utility, "fetcher")

      S.setprop(utility, "fetcher", fn fctx, url, fd ->
        acquire(f)
        inner.(fctx, url, fd)
      end)
    end

    nil
  end

  defp acquire(f) do
    opts = F.opts(f)
    rate = por(S.getprop(opts, "rate"), 5)
    burst = case S.getprop(opts, "burst") do nil -> rate; v -> v end

    # Refill according to elapsed time.
    now = F.now(f)
    elapsed = now - S.getprop(f, "last")
    S.setprop(f, "last", now)
    S.setprop(f, "tokens", min(burst, S.getprop(f, "tokens") + (elapsed / 1000) * rate))

    tokens = S.getprop(f, "tokens")

    if tokens >= 1 do
      S.setprop(f, "tokens", tokens - 1)
    else
      # Not enough tokens: wait for one to accrue, then consume it.
      needed = 1 - tokens
      wait_ms = ceil((needed / rate) * 1000)
      track(f, wait_ms)
      F.sleep(f, wait_ms)
      S.setprop(f, "last", F.now(f))
      S.setprop(f, "tokens", 0)
    end

    nil
  end

  defp track(f, wait_ms) do
    client = S.getprop(f, "client")
    track = F.track_node(client, "_ratelimit", S.jm(["throttled", 0, "waitMs", 0]))
    S.setprop(track, "throttled", S.getprop(track, "throttled") + 1)
    S.setprop(track, "waitMs", S.getprop(track, "waitMs") + wait_ms)
  end

  # Python `v or default`: falsy = nil, false, 0, 0.0, "".
  defp por(v, d) do
    if v == nil or v == false or v == 0 or v == "", do: d, else: v
  end
end
