# Univec SDK clienttrack feature
#
# Client tracking. Establishes a stable per-client session id at
# construction and stamps identifying headers on every request: a
# `User-Agent`, an `X-Client-Id` (session), and a fresh per-request
# `X-Request-Id`. This lets a server correlate all traffic from one SDK
# instance and each individual call. Header names, client name/version
# (`clientName`/`clientVersion`) and the id generator (`idgen`) are
# configurable; the session id and request counter are exposed on
# `client._clienttrack`. Caller-provided User-Agent / X-Client-Id headers
# are never clobbered.

defmodule Univec.Feature.Clienttrack do
  alias Voxgig.Struct, as: S
  alias Univec.Feature

  def new do
    f = Feature.base("clienttrack")
    S.setprop(f, "session", "")
    S.setprop(f, "requests", 0)
    Feature.install(f, "init", fn ctx, opts -> init(f, ctx, opts) end)
    Feature.install(f, "PostConstruct", fn ctx -> post_construct(f, ctx) end)
    Feature.install(f, "PreRequest", fn ctx -> pre_request(f, ctx) end)
    f
  end

  def init(f, ctx, options) do
    Feature.init_common(f, ctx, options)
    S.setprop(f, "requests", 0)
    nil
  end

  defp post_construct(f, _ctx) do
    if Feature.active?(f) do
      opts = Feature.opts(f)
      sid = S.getprop(opts, "sessionId")
      session = if pytrue?(sid), do: sid, else: genid(f, "session")
      S.setprop(f, "session", session)

      client = S.getprop(f, "client")

      S.setprop(
        client,
        "_clienttrack",
        S.jm(["session", session, "requests", 0, "clientName", name(f)])
      )
    end

    nil
  end

  defp pre_request(f, ctx) do
    if Feature.active?(f) do
      spec = S.getprop(ctx, "spec")

      if spec != nil do
        if S.getprop(spec, "headers") == nil do
          S.setprop(spec, "headers", S.jm([]))
        end

        if S.getprop(f, "session") == "" do
          sid = S.getprop(Feature.opts(f), "sessionId")
          session = if pytrue?(sid), do: sid, else: genid(f, "session")
          S.setprop(f, "session", session)
        end

        opts = Feature.opts(f)
        headers = S.getprop(opts, "headers")
        headers = if S.ismap(headers), do: headers, else: S.jm([])

        requests = S.getprop(f, "requests") + 1
        S.setprop(f, "requests", requests)
        request_id = genid(f, "request")

        spec_headers = S.getprop(spec, "headers")
        set_header(spec_headers, hdr_name(headers, "agent", "User-Agent"), name(f))
        set_header(spec_headers, hdr_name(headers, "client", "X-Client-Id"), S.getprop(f, "session"))
        S.setprop(spec_headers, hdr_name(headers, "request", "X-Request-Id"), request_id)

        client = S.getprop(f, "client")
        track = S.getprop(client, "_clienttrack")

        track =
          if track == nil do
            t = S.jm(["session", S.getprop(f, "session"), "requests", 0, "clientName", name(f)])
            S.setprop(client, "_clienttrack", t)
            t
          else
            track
          end

        S.setprop(track, "requests", requests)
        S.setprop(track, "lastRequestId", request_id)
      end
    end

    nil
  end

  # Do not clobber a caller-provided value (e.g. a custom User-Agent).
  defp set_header(headers, hname, value) do
    if not Feature.header_has?(headers, hname) do
      S.setprop(headers, hname, value)
    end

    nil
  end

  defp hdr_name(headers, key, default) do
    v = S.getprop(headers, key)
    if pytrue?(v), do: v, else: default
  end

  defp name(f) do
    opts = Feature.opts(f)
    n = por(S.getprop(opts, "clientName"), "Univec-SDK")
    v = por(S.getprop(opts, "clientVersion"), "0.0.1")
    to_string(n) <> "/" <> to_string(v)
  end

  defp genid(f, kind) do
    g = S.getprop(Feature.opts(f), "idgen")

    if S.isfunc(g) do
      g.(kind)
    else
      hex = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      first = String.slice(kind, 0, 1)
      String.slice(first <> "-" <> hex, 0, 20)
    end
  end

  # Python truthiness (nil / false / "" / 0 are falsey).
  defp pytrue?(v), do: not (v == nil or v == false or v == "" or v == 0)
  defp por(v, alt), do: if(pytrue?(v), do: v, else: alt)
end
