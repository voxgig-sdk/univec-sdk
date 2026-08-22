# ProjectName SDK
#
# The client is a reference-stable struct map node (mode/features/options
# plus the root ctx and utility). Functional API: build one with new/1 or
# test/2, then call entity factories or direct/2.

defmodule ProjectName do
  alias Voxgig.Struct, as: S
  alias ProjectName.Helpers, as: H
  alias ProjectName.{Utility, Context, Spec}

  def new(options \\ nil) do
    client = S.jm([])
    S.setprop(client, "mode", "live")
    S.setprop(client, "features", [])
    S.setprop(client, "options", nil)

    utility = Utility.new()
    S.setprop(client, "_utility", utility)

    # The process-wide config (sdkgen rung L2): read-only on the request path,
    # so every client shares one rather than rebuilding it.
    config = ProjectName.Config.shared_config()

    rootctx =
      Context.new(
        S.jm([
          "client", client,
          "utility", utility,
          "config", config,
          "options", if(options != nil, do: options, else: S.jm([])),
          "shared", S.jm([])
        ]),
        nil
      )

    S.setprop(client, "_rootctx", rootctx)

    opts = Utility.make_options(rootctx)
    S.setprop(client, "options", opts)

    if S.getpath(opts, "feature.test.active") == true, do: S.setprop(client, "mode", "test")
    S.setprop(rootctx, "options", opts)

    # Add features in the resolved order (make_options records an explicit
    # array order, else defaults to test-first). Ordering matters: the `test`
    # feature installs the base mock transport and the transport features
    # (retry/cache/netsim/proxy/ratelimit) wrap whatever is current, so `test`
    # must be added before them to sit at the base of the wrapper chain.
    feature_opts = H.or_(H.to_map(S.getprop(opts, "feature")), S.jm([]))
    feature_order = S.getpath(opts, "__derived__.featureorder")

    if S.islist(feature_order) and S.size(feature_order) > 0 do
      Enum.each(0..(S.size(feature_order) - 1), fn i ->
        fname = S.getelem(feature_order, i)
        fom = H.to_map(S.getprop(feature_opts, fname))

        if fom != nil and S.getprop(fom, "active") == true do
          Utility.feature_add(rootctx, ProjectName.Features.make_feature(fname))
        end
      end)
    end

    extend = S.getprop(opts, "extend")

    if S.islist(extend) and S.size(extend) > 0 do
      Enum.each(0..(S.size(extend) - 1), fn i ->
        fx = S.getelem(extend, i)
        if S.ismap(fx), do: Utility.feature_add(rootctx, fx)
      end)
    end

    Enum.each(S.getprop(client, "features"), fn fe -> Utility.feature_init(rootctx, fe) end)
    Utility.feature_hook(rootctx, "PostConstruct")

    client
  end

  def options_map(client) do
    out = S.clone(S.getprop(client, "options"))
    if S.ismap(out), do: out, else: S.jm([])
  end

  def get_utility(client), do: S.getprop(client, "_utility")
  def get_root_ctx(client), do: S.getprop(client, "_rootctx")
  def mode(client), do: S.getprop(client, "mode")

  def test(testopts \\ nil, sdkopts \\ nil) do
    sdkopts = S.clone(if(sdkopts != nil, do: sdkopts, else: S.jm([])))
    sdkopts = if S.ismap(sdkopts), do: sdkopts, else: S.jm([])

    testopts = S.clone(if(testopts != nil, do: testopts, else: S.jm([])))
    testopts = if S.ismap(testopts), do: testopts, else: S.jm([])
    S.setprop(testopts, "active", true)

    S.setpath(sdkopts, "feature.test", testopts)

    client = new(sdkopts)
    S.setprop(client, "mode", "test")
    client
  end

  def prepare(client, fetchargs \\ nil) do
    fetchargs = if S.ismap(fetchargs), do: fetchargs, else: S.jm([])
    ctrl = H.or_(H.to_map(S.getprop(fetchargs, "ctrl")), S.jm([]))

    ctx = Context.new(S.jm(["opname", "prepare", "ctrl", ctrl]), get_root_ctx(client))
    options = S.getprop(client, "options")

    path0 = H.or_(S.getprop(fetchargs, "path"), "")
    path = if is_binary(path0), do: path0, else: ""
    method0 = H.or_(S.getprop(fetchargs, "method"), "GET")
    method = if is_binary(method0), do: method0, else: "GET"
    params = H.or_(H.to_map(S.getprop(fetchargs, "params")), S.jm([]))
    query = H.or_(H.to_map(S.getprop(fetchargs, "query")), S.jm([]))

    headers = Utility.prepare_headers(ctx)

    base = strp(S.getprop(options, "base"))
    prefix = strp(S.getprop(options, "prefix"))
    suffix = strp(S.getprop(options, "suffix"))

    spec =
      Spec.new(
        S.jm([
          "base", base,
          "prefix", prefix,
          "suffix", suffix,
          "path", path,
          "method", method,
          "params", params,
          "query", query,
          "headers", headers,
          "body", S.getprop(fetchargs, "body"),
          "step", "start"
        ])
      )

    S.setprop(ctx, "spec", spec)

    uh = S.getprop(fetchargs, "headers")

    if S.ismap(uh) do
      Enum.each(H.entries(uh), fn {k, v} -> S.setprop(S.getprop(spec, "headers"), k, v) end)
    end

    {_spec, err} = Utility.prepare_auth(ctx)
    if err != nil, do: raise(err)

    {fetchdef, err2} = Utility.make_fetch_def(ctx)
    if err2 != nil, do: raise(err2)

    fetchdef
  end

  # Raw endpoint access is operator-controllable, like every entity op.
  # Blocking it means denying BOTH the 'direct' and 'graphql' tokens, since
  # either one reaches the same endpoint.
  def direct(client, fetchargs \\ nil) do
    if op_allowed?(client, "direct") do
      raw_request(client, fetchargs)
    else
      op_denied(client, "direct")
    end
  end

  # Is this raw-access op permitted by the SDK's allow.op option?
  defp op_allowed?(client, op) do
    allow = S.getpath(S.getprop(client, "options"), "allow.op")
    is_binary(allow) and String.contains?(allow, op)
  end

  defp op_denied(client, op) do
    allow = S.getpath(S.getprop(client, "options"), "allow.op")
    allow = if is_binary(allow), do: allow, else: ""

    S.jm([
      "ok",
      false,
      "err",
      "ProjectNameSDK: " <> op <> ": operation not allowed by" <>
        " SDK option allow.op value: \"" <> allow <> "\""
    ])
  end

  # Ungated request path shared by direct and graphql, each of which checks
  # its own allow.op token first. Private, rather than a flag on fetchargs: a
  # caller-supplied marker would let anyone opt straight back out of the gate
  # by passing it.
  defp raw_request(client, fetchargs) do
    fetchdef =
      try do
        prepare(client, fetchargs)
      rescue
        err -> {:direct_err, err}
      end

    case fetchdef do
      {:direct_err, err} ->
        S.jm(["ok", false, "err", err])

      _ ->
        fetchargs = if S.ismap(fetchargs), do: fetchargs, else: S.jm([])
        ctrl = H.or_(H.to_map(S.getprop(fetchargs, "ctrl")), S.jm([]))
        ctx = Context.new(S.jm(["opname", "direct", "ctrl", ctrl]), get_root_ctx(client))

        url = H.or_(S.getprop(fetchdef, "url"), "")
        {fetched, fetch_err} = Utility.fetcher(ctx, url, fetchdef)

        cond do
          fetch_err != nil ->
            S.jm(["ok", false, "err", fetch_err])

          fetched == nil ->
            S.jm(["ok", false, "err", Context.make_error(ctx, "direct_no_response", "response: undefined")])

          S.ismap(fetched) ->
            status = H.to_int(S.getprop(fetched, "status"))
            headers = H.or_(S.getprop(fetched, "headers"), S.jm([]))

            content_length =
              if S.ismap(headers), do: ProjectName.Feature.header_get(headers, "content-length"), else: nil

            no_body = status in [204, 304] or to_string(content_length) == "0"

            json_data =
              if no_body do
                nil
              else
                jf = S.getprop(fetched, "json")

                if S.isfunc(jf) do
                  try do
                    jf.()
                  rescue
                    _ -> nil
                  end
                else
                  nil
                end
              end

            S.jm(["ok", status >= 200 and status < 300, "status", status, "headers", headers, "data", json_data])

          true ->
            S.jm(["ok", false, "err", Context.make_error(ctx, "direct_invalid", "invalid response type")])
        end
    end
  end

  # Raw GraphQL access: the pressure valve that makes the generated surface's
  # deliberate omissions (per-call selection sets, typed filter builders,
  # batching, subscriptions) livable — the whole schema stays reachable.
  #
  # Thin wrapper over the same prepare/fetch path direct uses, with the one
  # thing raw direct cannot do for GraphQL: a GraphQL failure rides HTTP 200
  # as a top-level `errors` array, so status alone would report a failed
  # query as ok.
  #
  # NOTE: like direct, this bypasses the feature pipeline — no retry,
  # ratelimit or paging features apply.
  def graphql(client, query, variables \\ nil, ctrl \\ nil) do
    if not op_allowed?(client, "graphql") do
      op_denied(client, "graphql")
    else
      res =
        raw_request(client, S.jm([
          "method", "POST",
          "headers", S.jm(["content-type", "application/json"]),
          "body", S.jm([
            "query", query,
            "variables", if(S.ismap(variables), do: variables, else: S.jm([]))
          ]),
          "ctrl", if(S.ismap(ctrl), do: ctrl, else: S.jm([]))
        ]))

      # Errors are read BEFORE any status check: a GraphQL parse or
      # validation failure comes back as HTTP 400 carrying the standard
      # { errors: [...] } body, and the raw path represents a non-2xx as
      # ok:false with no err — so returning early on status would discard the
      # server's own diagnostics, which are the only useful part of that
      # response.
      errors = S.getpath(res, "data.errors")
      count = if S.islist(errors), do: S.size(errors), else: 0

      if count == 0 do
        res
      else
        first = S.getelem(errors, 0)
        msg = strp(S.getprop(first, "message"))
        msg = if msg == "", do: "graphql error", else: msg

        S.setprop(res, "ok", false)
        S.setprop(res, "err", "ProjectNameSDK: graphql: " <> msg)
        S.setprop(res, "graphql", errors)
        res
      end
    end
  end

  defp strp(v), do: if(is_binary(v), do: v, else: "")

  # <[SLOT]>
end
