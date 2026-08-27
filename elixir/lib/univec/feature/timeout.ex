# Univec SDK timeout feature
#
# Per-request timeout. Wraps the active transport with a deadline of `ms`
# milliseconds (default 30000; <= 0 disables). The fetch definition is
# annotated with a `timeout` (in seconds, for transports that honour it) and
# the elapsed time of each attempt is checked against the deadline; when the
# deadline is exceeded the request resolves to a `timeout` error instead of a
# late response. The clock (`now`) is injectable for deterministic tests.

defmodule Univec.Feature.Timeout do
  alias Voxgig.Struct, as: S
  alias Univec.Feature, as: F
  alias Univec.Context

  def new do
    f = F.base("timeout")
    F.install(f, "init", fn ctx, opts -> init(f, ctx, opts) end)
    f
  end

  def init(f, ctx, options) do
    active = F.init_common(f, ctx, options)

    if active do
      utility = S.getprop(ctx, "utility")
      inner = S.getprop(utility, "fetcher")
      S.setprop(utility, "fetcher", fn fctx, url, fd -> with_timeout(f, fctx, url, fd, inner) end)
    end

    nil
  end

  defp with_timeout(f, ctx, url, fetchdef, inner) do
    opts = F.opts(f)
    ms = case S.getprop(opts, "ms") do nil -> 30000; v -> v end

    if ms <= 0 do
      inner.(ctx, url, fetchdef)
    else
      # Annotate the fetch definition so a real transport can cancel itself
      # (Python-idiomatic analog of an abort signal). Copy so the caller's
      # fetchdef is not mutated.
      fetchdef = if S.ismap(fetchdef), do: S.clone(fetchdef), else: S.jm([])
      S.setprop(fetchdef, "timeout", ms / 1000)

      start = F.now(f)
      {res, err} = inner.(ctx, url, fetchdef)
      elapsed = F.now(f) - start

      if elapsed > ms do
        track(f, ms)
        {nil, Context.make_error(ctx, "timeout", "Request exceeded timeout of " <> to_string(ms) <> "ms")}
      else
        {res, err}
      end
    end
  end

  defp track(f, ms) do
    client = S.getprop(f, "client")
    track = F.track_node(client, "_timeout", S.jm(["count", 0, "ms", ms]))
    S.setprop(track, "count", S.getprop(track, "count") + 1)
  end
end
