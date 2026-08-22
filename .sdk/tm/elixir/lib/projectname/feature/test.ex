# Univec SDK test feature
#
# In-memory mock transport for offline tests. Installs a fetcher that
# resolves ops against a per-entity data store (from options.entity) using
# the vendored struct select/transform engine — the same query shaping as
# the live SDK. An optional `net` block simulates latency/failures.

defmodule Univec.Feature.Test do
  alias Voxgig.Struct, as: S
  alias Univec.Helpers, as: H
  alias Univec.{Feature, Context, Utility}

  def new do
    f = Feature.base("test")
    Feature.install(f, "init", fn ctx, opts -> init(f, ctx, opts) end)
    f
  end

  def init(f, ctx, options) do
    Feature.init_common(f, ctx, options)
    opts = Feature.opts(f)

    entity = S.getprop(opts, "entity")
    entity = if S.ismap(entity), do: entity, else: S.jm([])

    S.setprop(S.getprop(ctx, "client"), "mode", "test")

    # Ensure entity records carry their id (the map key).
    S.walk(entity,
      before: fn key, val, _parent, path ->
        if S.size(path) == 2 and S.ismap(val) and key != nil, do: S.setprop(val, "id", key)
        val
      end
    )

    test_fetcher = fn fctx, _url, _fetchdef -> respond_op(f, entity, fctx) end

    utility = S.getprop(ctx, "utility")
    net = S.getprop(opts, "net")

    if S.ismap(net) do
      S.setprop(utility, "fetcher", make_netsim(f, net, test_fetcher))
    else
      S.setprop(utility, "fetcher", test_fetcher)
    end

    nil
  end

  defp respond(status, data, extra \\ nil) do
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

    {out, nil}
  end

  defp resolve_match(fctx, explicit) do
    if S.ismap(explicit) and S.size(explicit) > 0 do
      explicit
    else
      Enum.find_value([S.getprop(fctx, "match"), S.getprop(fctx, "data")], S.jm([]), fn src ->
        v = if src != nil, do: S.getprop(src, "id"), else: nil
        if v != nil and v != "__UNDEFINED__", do: S.jm(["id", v])
      end)
    end
  end

  defp respond_op(f, entity, fctx) do
    op = S.getprop(fctx, "op")
    opname = S.getprop(op, "name")
    entmap = S.getprop(entity, S.getprop(op, "entity"))
    entmap = if S.ismap(entmap), do: entmap, else: S.jm([])

    case opname do
      "load" ->
        args = build_args(f, fctx, op, resolve_match(fctx, S.getprop(fctx, "reqmatch")))
        found = S.select(entmap, args)
        ent = S.getelem(found, 0)

        if ent == nil do
          respond(404, nil, S.jm(["statusText", "Not found"]))
        else
          S.delprop(ent, "$KEY")
          respond(200, S.clone(ent))
        end

      "list" ->
        args = build_args(f, fctx, op, S.getprop(fctx, "reqmatch"))
        found = S.select(entmap, args)

        if found == nil do
          respond(404, nil, S.jm(["statusText", "Not found"]))
        else
          if S.islist(found) and S.size(found) > 0 do
            Enum.each(0..(S.size(found) - 1), fn i -> S.delprop(S.getelem(found, i), "$KEY") end)
          end

          respond(200, S.clone(found))
        end

      "update" ->
        reqdata = S.getprop(fctx, "reqdata")

        update_match =
          if S.ismap(reqdata) do
            um = S.jm([])
            if S.getprop(reqdata, "id") != nil, do: S.setprop(um, "id", S.getprop(reqdata, "id"))
            alias_map = S.getprop(op, "alias")

            if alias_map != nil do
              alias_id = S.getprop(alias_map, "id")

              if alias_id != nil and S.getprop(reqdata, alias_id) != nil do
                S.setprop(um, alias_id, S.getprop(reqdata, alias_id))
              end
            end

            um
          else
            S.jm([])
          end

        update_match = if S.size(update_match) == 0, do: resolve_match(fctx, S.jm([])), else: update_match
        args = build_args(f, fctx, op, update_match)
        found = S.select(entmap, args)
        ent = S.getelem(found, 0)

        ent =
          if ent == nil and S.ismap(entmap) do
            ks = S.keysof(entmap)
            Enum.find_value(ks, fn k -> v = S.getprop(entmap, k); if S.ismap(v), do: v end)
          else
            ent
          end

        if ent == nil do
          respond(404, nil, S.jm(["statusText", "Not found"]))
        else
          if S.ismap(ent) and reqdata != nil do
            Enum.each(H.entries(reqdata), fn {k, v} -> S.setprop(ent, k, v) end)
          end

          S.delprop(ent, "$KEY")
          respond(200, S.clone(ent))
        end

      "remove" ->
        args = build_args(f, fctx, op, resolve_match(fctx, S.getprop(fctx, "reqmatch")))
        found = S.select(entmap, args)
        ent = S.getelem(found, 0)

        if S.ismap(ent) do
          eid = S.getprop(ent, "id")
          S.delprop(entmap, eid)
        end

        respond(200, nil)

      "create" ->
        build_args(f, fctx, op, S.getprop(fctx, "reqdata"))
        eid = Utility.param(fctx, "id")
        eid = if eid == nil, do: gen_id(), else: eid
        ent = S.clone(S.getprop(fctx, "reqdata"))

        if S.ismap(ent) do
          S.setprop(ent, "id", eid)
          if is_binary(eid), do: S.setprop(entmap, eid, ent)
          S.delprop(ent, "$KEY")
          respond(200, S.clone(ent))
        else
          respond(200, ent)
        end

      _ ->
        respond(404, nil, S.jm(["statusText", "Unknown operation"]))
    end
  end

  defp gen_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  # Build a struct select query ($AND of $OR alternatives) from the required
  # params + id, resolving each value through the pipeline param resolver.
  def build_args(_f, ctx, op, args) do
    opname = S.getprop(op, "name")
    config = S.getprop(ctx, "config")
    entname = Context.entity_name(S.getprop(ctx, "entity"))
    points = S.getpath(config, "entity." <> entname <> ".op." <> opname <> ".points")
    point = S.getelem(points, -1)
    params_path = S.getpath(point, "args.params")
    reqd_params = S.select(params_path, S.jm(["reqd", true]))
    reqd = S.transform(reqd_params, S.jt(["`$EACH`", "", "`$KEY.name`"]))

    qand = S.jt([])
    q = S.jm(["`$AND`", qand])

    if args != nil do
      Enum.each(S.keysof(args), fn key ->
        is_id = key == "id"
        selected = S.select(reqd, key)
        is_reqd = not S.isempty(selected)

        if is_id or is_reqd do
          v = Utility.param(ctx, key)
          ka = if S.getprop(op, "alias") != nil, do: S.getprop(S.getprop(op, "alias"), key), else: nil

          qor = S.jt([S.jm([key, v])])
          if is_binary(ka), do: Feature.list_push(qor, S.jm([ka, v]))

          Feature.list_push(qand, S.jm(["`$OR`", qor]))
        end
      end)
    end

    ctrl = S.getprop(ctx, "ctrl")
    explain = if ctrl != nil, do: S.getprop(ctrl, "explain"), else: nil
    if explain != nil, do: S.setprop(explain, "test", S.jm(["query", q]))

    q
  end

  # Counter-driven network simulation over the mock transport.
  defp make_netsim(f, net, inner) do
    S.setprop(f, "_netcalls", 0)

    # Injectable sleep lives in the `net` block (net.sleep), not feature opts.
    netsleep = fn ms ->
      if ms != nil and ms > 0 do
        ns = S.getprop(net, "sleep")
        if S.isfunc(ns), do: ns.(ms), else: :timer.sleep(trunc(ms))
      end
    end

    fn fctx, url, fetchdef ->
      call = S.getprop(f, "_netcalls") + 1
      S.setprop(f, "_netcalls", call)

      cond do
        S.getprop(net, "offline") == true ->
          netsleep.(pick_latency(net))
          {nil, Context.make_error(fctx, "netsim_offline", "Simulated network offline (URL was: \"" <> url <> "\")")}

        call <= H.to_int(H.or_(S.getprop(net, "errorTimes"), 0)) ->
          netsleep.(pick_latency(net))
          {nil, Context.make_error(fctx, "netsim_conn", "Simulated connection error (call " <> Integer.to_string(call) <> ")")}

        call <= H.to_int(H.or_(S.getprop(net, "failTimes"), 0)) ->
          netsleep.(pick_latency(net))
          status = H.or_(S.getprop(net, "failStatus"), 503)

          respond(status, nil,
            S.jm(["statusText", "Simulated Failure", "headers", S.jm([])]))

        true ->
          netsleep.(pick_latency(net))
          inner.(fctx, url, fetchdef)
      end
    end
  end

  defp pick_latency(net) do
    latency = S.getprop(net, "latency")

    cond do
      latency == nil -> 0
      is_number(latency) and not is_boolean(latency) -> if latency < 0, do: 0, else: latency
      not S.ismap(latency) -> 0
      true ->
        mn = H.to_int(H.or_(S.getprop(latency, "min"), 0))
        mxv = S.getprop(latency, "max")
        mx = if mxv == nil, do: mn, else: H.to_int(mxv)
        if mx <= mn, do: mn, else: mn + div(mx - mn, 2)
    end
  end
end
