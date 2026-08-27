# Univec SDK proxy feature
#
# Outbound HTTP(S) proxy support. Wraps the active transport and attaches
# proxy routing to each request's fetch definition. The proxy target comes
# from options (`url`) or, when `fromEnv` is set, the standard
# HTTPS_PROXY / HTTP_PROXY / NO_PROXY environment variables. The request is
# annotated on a cloned fetch definition: `proxy` carries the proxy URL and
# `proxies` carries a requests-style scheme map, for a custom transport to
# honour. An `agent` factory may also be supplied; its product is attached
# as `agent` / `dispatcher`. Hosts matching `noProxy` bypass the proxy.

defmodule Univec.Feature.Proxy do
  alias Voxgig.Struct, as: S
  alias Univec.Feature, as: F

  def new do
    f = F.base("proxy")
    F.install(f, "init", fn ctx, opts -> init(f, ctx, opts) end)
    f
  end

  def init(f, ctx, options) do
    active = F.init_common(f, ctx, options)

    if active do
      opts = F.opts(f)
      url = S.getprop(opts, "url")
      no_proxy = S.getprop(opts, "noProxy")

      {url, no_proxy} =
        if S.getprop(opts, "fromEnv") == true do
          u =
            firstv([
              url,
              System.get_env("HTTPS_PROXY"),
              System.get_env("https_proxy"),
              System.get_env("HTTP_PROXY"),
              System.get_env("http_proxy")
            ])

          n = firstv([no_proxy, System.get_env("NO_PROXY"), System.get_env("no_proxy")])
          {u, n}
        else
          {url, no_proxy}
        end

      np_list =
        cond do
          is_binary(no_proxy) -> Regex.split(~r/\s*,\s*/, no_proxy)
          true -> opt_list(no_proxy, [])
        end

      np_list = Enum.filter(np_list, fn s -> s != nil and s != "" end)

      S.setprop(f, "url", url)
      S.setprop(f, "no_proxy", S.jt(np_list))

      utility = S.getprop(ctx, "utility")
      inner = S.getprop(utility, "fetcher")

      S.setprop(utility, "fetcher", fn fctx, fullurl, fetchdef ->
        routed = route(f, fullurl, fetchdef)
        inner.(fctx, fullurl, routed)
      end)
    end

    nil
  end

  defp route(f, url, fetchdef) do
    purl = S.getprop(f, "url")

    if purl == nil or bypass?(f, url) do
      fetchdef
    else
      out = if S.ismap(fetchdef), do: S.clone(fetchdef), else: S.jm([])
      S.setprop(out, "proxy", purl)
      S.setprop(out, "proxies", S.jm(["http", purl, "https", purl]))

      agent = S.getprop(F.opts(f), "agent")

      if S.isfunc(agent) do
        # Factory returns a transport-specific agent/dispatcher.
        made = agent.(purl, url)
        S.setprop(out, "dispatcher", made)
        S.setprop(out, "agent", made)
      end

      track(f)
      out
    end
  end

  defp bypass?(f, url) do
    no_proxy = opt_list(S.getprop(f, "no_proxy"), [])

    if no_proxy == [] do
      false
    else
      host =
        case Regex.run(~r/^[a-z]+:\/\/([^\/:]+)/i, url) do
          [_, h | _] -> h
          _ -> url
        end

      Enum.any?(no_proxy, fn np ->
        np == "*" or host == np or
          String.ends_with?(host, "." <> Regex.replace(~r/^\./, np, ""))
      end)
    end
  end

  defp track(f) do
    client = S.getprop(f, "client")
    track = F.track_node(client, "_proxy", S.jm(["routed", 0, "url", S.getprop(f, "url")]))
    S.setprop(track, "routed", S.getprop(track, "routed") + 1)
  end

  # First present value (Python `a or b or ...`): nil / false / "" and empty
  # struct nodes are skipped, mirroring Python truthiness for the env chain.
  defp firstv(list), do: Enum.find(list, &presentv/1)

  defp presentv(v) do
    cond do
      v == nil -> false
      v == false -> false
      v == "" -> false
      S.isnode(v) -> not S.isempty(v)
      true -> true
    end
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
