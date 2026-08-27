# Univec SDK cache feature
#
# Response caching for safe (read) requests. Wraps the active transport and
# serves a fresh cached snapshot instead of hitting the network when the same
# method+URL was fetched within `ttl` ms (default 5000). Only successful (2xx)
# responses to cacheable methods (default: GET) are stored, keyed by
# method+URL. The cache is bounded (`max` entries, default 256, oldest evicted
# first) and every hit/miss is recorded on `client._cache` for inspection.
# Response bodies are snapshotted on capture so both the current caller and
# later hits can read the JSON body repeatedly.

defmodule Univec.Feature.Cache do
  alias Voxgig.Struct, as: S
  alias Univec.Helpers, as: H
  alias Univec.Feature, as: F

  def new do
    f = F.base("cache")
    F.install(f, "init", fn ctx, opts -> init(f, ctx, opts) end)
    f
  end

  def init(f, ctx, options) do
    active = F.init_common(f, ctx, options)

    if active do
      S.setprop(f, "store", S.jm([]))

      utility = S.getprop(ctx, "utility")
      inner = S.getprop(utility, "fetcher")
      S.setprop(utility, "fetcher", fn fctx, url, fd -> through(f, fctx, url, fd, inner) end)
    end

    nil
  end

  defp through(f, ctx, url, fetchdef, inner) do
    opts = F.opts(f)
    store = S.getprop(f, "store")

    method =
      if S.ismap(fetchdef) and S.getprop(fetchdef, "method") != nil do
        String.upcase(to_string(S.getprop(fetchdef, "method")))
      else
        "GET"
      end

    methods = opt_list(S.getprop(opts, "methods"), ["GET"])

    if method not in methods do
      inner.(ctx, url, fetchdef)
    else
      key = method <> " " <> url
      now = F.now(f)
      hit = S.getprop(store, key)

      if hit != nil and S.getprop(hit, "expiry") > now do
        track(f, "hit")
        {replay(S.getprop(hit, "snapshot")), nil}
      else
        {res, err} = inner.(ctx, url, fetchdef)

        if err == nil and cacheable(res) do
          snap = snapshot(res)
          ttl = case S.getprop(opts, "ttl") do nil -> 5000; v -> v end
          evict(f)
          S.setprop(store, key, S.jm(["expiry", now + ttl, "snapshot", snap]))
          track(f, "miss")
          {replay(snap), nil}
        else
          track(f, "bypass")
          {res, err}
        end
      end
    end
  end

  defp cacheable(res) do
    if not S.ismap(res) do
      false
    else
      status = S.getprop(res, "status")

      if not (is_number(status) and not is_boolean(status)) do
        false
      else
        status >= 200 and status < 300
      end
    end
  end

  defp snapshot(res) do
    jf = S.getprop(res, "json")

    data =
      if S.isfunc(jf) do
        try do
          jf.()
        rescue
          _ -> nil
        end
      else
        nil
      end

    headers = S.jm([])
    raw = S.getprop(res, "headers")

    if S.ismap(raw) do
      Enum.each(H.entries(raw), fn {k, v} ->
        S.setprop(headers, String.downcase(to_string(k)), v)
      end)
    end

    S.jm([
      "status", S.getprop(res, "status"),
      "statusText", S.getprop(res, "statusText"),
      "data", data,
      "headers", headers
    ])
  end

  defp replay(snap) do
    data = S.getprop(snap, "data")
    headers = S.getprop(snap, "headers")
    headers = if headers == nil, do: S.jm([]), else: S.clone(headers)

    S.jm([
      "status", S.getprop(snap, "status"),
      "statusText", S.getprop(snap, "statusText"),
      "body", "not-used",
      "json", fn -> data end,
      "headers", headers
    ])
  end

  defp evict(f) do
    store = S.getprop(f, "store")
    mx = case S.getprop(F.opts(f), "max") do nil -> 256; v -> v end
    do_evict(store, mx)
  end

  defp do_evict(store, mx) do
    if S.size(store) >= mx do
      # keysof is SORTED order; evicting the first key removes the "oldest".
      case S.keysof(store) do
        [] -> nil
        [oldest | _] ->
          S.delprop(store, oldest)
          do_evict(store, mx)
      end
    end
  end

  defp track(f, kind) do
    client = S.getprop(f, "client")
    track = F.track_node(client, "_cache", S.jm(["hit", 0, "miss", 0, "bypass", 0]))
    S.setprop(track, kind, S.getprop(track, kind) + 1)
  end

  # Struct list node -> plain Elixir list; nil/empty -> default.
  defp opt_list(v, default) do
    cond do
      v == nil -> default
      S.islist(v) and S.isempty(v) -> default
      S.islist(v) -> Enum.map(0..(S.size(v) - 1), fn i -> S.getelem(v, i) end)
      true -> default
    end
  end
end
