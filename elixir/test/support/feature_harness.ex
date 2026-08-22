# Univec SDK feature test harness
#
# Offline harness that drives each feature through a faithful miniature of
# the real operation pipeline against a configurable mock transport — same
# hook order and short-circuit rules as the generated op runner, no live
# server. Everything is a vendored-struct node, exactly like the SDK.

defmodule Univec.FeatureHarness do
  alias Voxgig.Struct, as: S
  alias Univec.Helpers, as: H
  alias Univec.{Control, Spec, Result, Context, Features}

  # True when this SDK was generated with the named feature.
  def has_feature(name) do
    feature = S.getprop(Univec.Config.make_config(), "feature")
    S.ismap(feature) and S.getprop(feature, name) != nil
  end

  # --- deterministic clock -------------------------------------------------
  # now() advances only when sleep(ms) is called.

  def make_clock(start \\ 0) do
    S.jm(["_t", start])
  end

  def clock_now(clock), do: fn -> S.getprop(clock, "_t") end
  def clock_sleep(clock), do: fn ms -> S.setprop(clock, "_t", S.getprop(clock, "_t") + (ms || 0)) end
  def clock_time(clock), do: S.getprop(clock, "_t")
  def clock_advance(clock, ms), do: S.setprop(clock, "_t", S.getprop(clock, "_t") + ms)

  # --- transport helpers ---------------------------------------------------

  def make_response(status, data \\ nil, headers \\ nil) do
    lower = S.jm([])

    if S.ismap(headers) do
      Enum.each(H.entries(headers), fn {k, v} -> S.setprop(lower, String.downcase(to_string(k)), v) end)
    end

    S.jm([
      "status", status,
      "statusText", if(is_integer(status) and status < 400, do: "OK", else: "ERR"),
      "body", "not-used",
      "json", fn -> data end,
      "headers", lower
    ])
  end

  def default_server do
    fn _ctx, _url, fetchdef ->
      method = String.upcase(to_string(H.or_(S.getprop(fetchdef, "method"), "GET")))

      if method == "GET" do
        {make_response(200, S.jm(["ok", true, "method", method])), nil}
      else
        {make_response(200, S.jm(["ok", true, "method", method, "echo", S.getprop(fetchdef, "body")])), nil}
      end
    end
  end

  # A transport recording every call. `reply` (fn n, fetchdef -> resp | {resp, err})
  # customises responses. Returns {server_fn, calls_node}.
  def recording_server(reply \\ nil) do
    calls = S.jt([])

    server = fn _ctx, url, fetchdef ->
      S.setprop(calls, S.size(calls), S.jm(["url", url, "fetchdef", fetchdef]))
      n = S.size(calls)

      if reply != nil do
        out = reply.(n, fetchdef)

        case out do
          {resp, err} -> {resp, err}
          resp -> {resp, nil}
        end
      else
        {make_response(200, S.jm(["ok", true, "n", n])), nil}
      end
    end

    {server, calls}
  end

  def default_method("create"), do: "POST"
  def default_method("update"), do: "PATCH"
  def default_method("remove"), do: "DELETE"
  def default_method(_), do: "GET"

  def build_url(spec) do
    query = H.or_(S.getprop(spec, "query"), S.jm([]))

    keys =
      S.keysof(query)
      |> Enum.filter(fn k -> S.getprop(query, k) != nil end)
      |> Enum.sort()

    qs =
      keys
      |> Enum.map(fn k -> S.escurl(to_string(k)) <> "=" <> S.escurl(to_string(S.getprop(query, k))) end)
      |> Enum.join("&")

    S.getprop(spec, "base") <> H.or_(S.getprop(spec, "path"), "") <> if(qs != "", do: "?" <> qs, else: "")
  end

  # --- mini pipeline objects ----------------------------------------------

  defp mk_utility(fetcher) do
    u = S.jm([])
    S.setprop(u, "fetcher", fetcher)

    param =
      fn ctx, name ->
        spec = S.getprop(ctx, "spec")
        params = if spec != nil, do: S.getprop(spec, "params"), else: nil
        query = if spec != nil, do: S.getprop(spec, "query"), else: nil
        val = if S.ismap(params), do: S.getprop(params, name), else: nil
        if val != nil, do: val, else: if(S.ismap(query), do: S.getprop(query, name), else: nil)
      end

    S.setprop(u, "param", param)
    u
  end

  defp mk_client(mode, options) do
    c = S.jm([])
    S.setprop(c, "mode", mode)
    S.setprop(c, "features", [])
    S.setprop(c, "options", options)
    c
  end

  defp mk_op(name, entity) do
    S.jm(["name", name, "entity", entity, "input", "match", "points", S.jt([]), "alias", nil])
  end

  defp mk_entity(name), do: S.jm(["_name", name])

  defp mk_ctx(client, utility, op, entity, ctrl) do
    ctx = S.jm([])
    S.setprop(ctx, "id", "C" <> Integer.to_string(:rand.uniform(89_999_999) + 10_000_000))
    S.setprop(ctx, "client", client)
    S.setprop(ctx, "utility", utility)
    S.setprop(ctx, "out", S.jm([]))
    S.setprop(ctx, "ctrl", if(ctrl != nil, do: ctrl, else: Control.new(nil)))
    S.setprop(ctx, "meta", S.jm([]))
    S.setprop(ctx, "op", op)
    S.setprop(ctx, "entity", entity)
    S.setprop(ctx, "spec", nil)
    S.setprop(ctx, "response", nil)
    S.setprop(ctx, "result", nil)
    S.setprop(ctx, "shared", S.jm([]))
    ctx
  end

  # --- construction --------------------------------------------------------
  # opts: %{features: [%{"name"=>..,"options"=>node}], server:, mode:, base:, headers: node}
  def new(feature_specs, opts \\ %{}) do
    base = Map.get(opts, :base, "http://api.test")
    headers = Map.get(opts, :headers) || S.jm([])
    server = Map.get(opts, :server) || default_server()
    mode = Map.get(opts, :mode, "test")

    utility = mk_utility(server)

    client =
      mk_client(mode, S.jm(["base", base, "headers", S.clone(headers), "feature", S.jm([])]))

    rootctx = mk_ctx(client, utility, mk_op("root", "_"), nil, nil)

    h = %{client: client, utility: utility, rootctx: rootctx, base: base, headers: headers}

    Enum.each(feature_specs, fn fspec ->
      name = S.getprop(fspec, "name")

      if has_feature(name) do
        feature = Features.make_feature(name)
        fopts = S.jm(["active", true])
        fspec_opts = S.getprop(fspec, "options")

        if S.ismap(fspec_opts) do
          Enum.each(H.entries(fspec_opts), fn {k, v} -> S.setprop(fopts, k, v) end)
        end

        S.setprop(S.getprop(client, "options") |> S.getprop("feature"), S.getprop(feature, "name"), fopts)
        init_fn = S.getprop(feature, "init")
        if S.isfunc(init_fn), do: init_fn.(rootctx, fopts)
        S.setprop(client, "features", S.getprop(client, "features") ++ [feature])
      end
    end)

    feature_hook(h, rootctx, "PostConstruct")
    h
  end

  def feature(h, name) do
    Enum.find(S.getprop(h.client, "features"), fn f -> S.getprop(f, "name") == name end)
  end

  def feature_hook(h, ctx, name) do
    Enum.each(S.getprop(h.client, "features"), fn f ->
      method = S.getprop(f, name)
      if S.isfunc(method), do: method.(ctx)
    end)
  end

  defp populate_result(ctx, response, fetch_err) do
    result = Result.new(nil)
    S.setprop(ctx, "result", result)

    cond do
      fetch_err != nil ->
        S.setprop(result, "err", fetch_err)

      response == nil ->
        S.setprop(result, "err", Context.make_error(ctx, "request_no_response", "response: undefined"))

      H.is_error(response) ->
        S.setprop(result, "err", response)

      true ->
        S.setprop(result, "status", S.getprop(response, "status"))
        S.setprop(result, "status_text", H.or_(S.getprop(response, "statusText"), ""))
        S.setprop(result, "headers", S.clone(H.or_(S.getprop(response, "headers"), S.jm([]))))

        jf = S.getprop(response, "json")
        if S.isfunc(jf), do: S.setprop(result, "body", jf.())
        S.setprop(result, "resdata", S.getprop(result, "body"))

        status = S.getprop(result, "status")

        cond do
          is_integer(status) and status >= 400 ->
            S.setprop(result, "err",
              Context.make_error(ctx, "request_status",
                "request: " <> Integer.to_string(status) <> ": " <> H.or_(S.getprop(result, "status_text"), "")))

          S.getprop(response, "err") != nil ->
            S.setprop(result, "err", S.getprop(response, "err"))

          true ->
            :ok
        end

        if S.getprop(result, "err") == nil, do: S.setprop(result, "ok", true)
    end
  end

  # Run one op through the mini pipeline. opts is a keyword/map:
  #   op:, entity:, method:, path:, query:(node), headers:(node), body:, ctrl:(node)
  def op(h, opts \\ %{}) do
    opname = Map.get(opts, :op, "load")
    entity = Map.get(opts, :entity, "widget")
    method = Map.get(opts, :method) || default_method(opname)
    ctrl = Control.new(Map.get(opts, :ctrl) || S.jm([]))

    ctx = mk_ctx(h.client, h.utility, mk_op(opname, entity), mk_entity(entity), ctrl)

    feature_hook(h, ctx, "PostConstructEntity")

    try do
      feature_hook(h, ctx, "PrePoint")
      pre_point = S.getprop(S.getprop(ctx, "out"), "point")
      if H.is_error(pre_point), do: throw({:harness_raise, pre_point})

      feature_hook(h, ctx, "PreSpec")
      spec = S.getprop(S.getprop(ctx, "out"), "spec")

      spec =
        if spec == nil do
          merged = S.clone(h.headers)
          uh = Map.get(opts, :headers)
          if S.ismap(uh), do: Enum.each(H.entries(uh), fn {k, v} -> S.setprop(merged, k, v) end)

          Spec.new(
            S.jm([
              "method", method,
              "base", h.base,
              "path", Map.get(opts, :path) || ("/" <> entity),
              "params", S.jm([]),
              "headers", merged,
              "query", S.clone(Map.get(opts, :query) || S.jm([])),
              "body", Map.get(opts, :body),
              "step", "start"
            ])
          )
        else
          spec
        end

      S.setprop(ctx, "spec", spec)

      feature_hook(h, ctx, "PreRequest")
      S.setprop(spec, "url", build_url(spec))

      response = S.getprop(S.getprop(ctx, "out"), "request")

      {response, fetch_err} =
        if response == nil do
          fetchdef =
            S.jm([
              "url", S.getprop(spec, "url"),
              "method", S.getprop(spec, "method"),
              "headers", S.getprop(spec, "headers"),
              "body", S.getprop(spec, "body")
            ])

          S.getprop(h.utility, "fetcher").(ctx, S.getprop(fetchdef, "url"), fetchdef)
        else
          {response, nil}
        end

      S.setprop(ctx, "response", response)

      feature_hook(h, ctx, "PreResponse")
      populate_result(ctx, response, fetch_err)
      feature_hook(h, ctx, "PreResult")
      feature_hook(h, ctx, "PreDone")

      result = S.getprop(ctx, "result")

      if result != nil and S.getprop(result, "ok") == true do
        %{ok: true, data: S.getprop(result, "resdata"), result: result, ctx: ctx, error: nil}
      else
        err =
          if result != nil and S.getprop(result, "err") != nil do
            S.getprop(result, "err")
          else
            Context.make_error(ctx, "op_failed", "operation failed")
          end

        throw({:harness_raise, err})
      end
    rescue
      err ->
        S.setprop(S.getprop(ctx, "ctrl"), "err", err)
        feature_hook(h, ctx, "PreUnexpected")
        %{ok: false, error: err, result: S.getprop(ctx, "result"), ctx: ctx, data: nil}
    catch
      {:harness_raise, err} ->
        S.setprop(S.getprop(ctx, "ctrl"), "err", err)
        feature_hook(h, ctx, "PreUnexpected")
        %{ok: false, error: err, result: S.getprop(ctx, "result"), ctx: ctx, data: nil}
    end
  end
end
