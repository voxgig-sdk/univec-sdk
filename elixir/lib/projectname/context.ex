# Univec SDK context
#
# The context is a reference-stable struct map node. Fields inherit from a
# base context (the client root ctx, then the entity ctx) exactly like the
# donor, so a feature hook that mutates ctx (or a nested spec/result/ctrl
# node) is seen by every later stage.

defmodule Univec.Context do
  alias Voxgig.Struct, as: S
  alias Univec.Helpers, as: H
  alias Univec.{Control, Operation, Error}

  def entity_name(entity) do
    if S.ismap(entity) do
      n = S.getprop(entity, "_name")
      if n != nil, do: n, else: "_"
    else
      "_"
    end
  end

  def make_error(ctx, code, msg), do: Error.new(code, msg, ctx)

  def new(ctxmap \\ nil, basectx \\ nil) do
    cm = if S.ismap(ctxmap), do: ctxmap, else: nil
    gp = fn k -> H.get_ctx_prop(cm, k) end
    bp = fn k -> if basectx != nil, do: S.getprop(basectx, k), else: nil end
    inh = fn k -> v = gp.(k); if(v != nil, do: v, else: bp.(k)) end
    inh_map = fn k -> v = H.to_map(gp.(k)); if(v != nil, do: v, else: bp.(k)) end

    ctx = S.jm([])
    S.setprop(ctx, "id", "C" <> Integer.to_string(:rand.uniform(89_999_999) + 10_000_000))
    S.setprop(ctx, "out", S.jm([]))
    S.setprop(ctx, "client", inh.("client"))
    S.setprop(ctx, "utility", inh.("utility"))

    # Ctrl.
    ctrl_raw = gp.("ctrl")

    cond do
      S.ismap(ctrl_raw) ->
        ctrl = Control.new(nil)
        te = S.getprop(ctrl_raw, "throw_err")

        if te != nil do
          S.setprop(ctrl, "throw_err", te)
        else
          t = S.getprop(ctrl_raw, "throw")
          if is_boolean(t), do: S.setprop(ctrl, "throw_err", t)
        end

        ex = S.getprop(ctrl_raw, "explain")
        if S.ismap(ex), do: S.setprop(ctrl, "explain", ex)
        ac = S.getprop(ctrl_raw, "actor")
        if ac != nil, do: S.setprop(ctrl, "actor", ac)
        pg = S.getprop(ctrl_raw, "paging")
        if S.ismap(pg), do: S.setprop(ctrl, "paging", pg)
        S.setprop(ctx, "ctrl", ctrl)

      basectx != nil and bp.("ctrl") != nil ->
        S.setprop(ctx, "ctrl", bp.("ctrl"))

      true ->
        S.setprop(ctx, "ctrl", Control.new(nil))
    end

    # Meta.
    m = gp.("meta")
    S.setprop(ctx, "meta", cond do
      S.ismap(m) -> m
      basectx != nil and bp.("meta") != nil -> bp.("meta")
      true -> S.jm([])
    end)

    S.setprop(ctx, "config", inh_map.("config"))
    S.setprop(ctx, "entopts", inh_map.("entopts"))
    S.setprop(ctx, "options", inh_map.("options"))
    S.setprop(ctx, "entity", inh.("entity"))
    S.setprop(ctx, "shared", inh_map.("shared"))

    opmap = inh_map.("opmap")
    S.setprop(ctx, "opmap", if(opmap != nil, do: opmap, else: S.jm([])))

    S.setprop(ctx, "data", H.or_(H.to_map(gp.("data")), S.jm([])))
    S.setprop(ctx, "reqdata", H.or_(H.to_map(gp.("reqdata")), S.jm([])))
    S.setprop(ctx, "match", H.or_(H.to_map(gp.("match")), S.jm([])))
    S.setprop(ctx, "reqmatch", H.or_(H.to_map(gp.("reqmatch")), S.jm([])))

    S.setprop(ctx, "point", inh.("point"))
    S.setprop(ctx, "spec", inh.("spec"))
    S.setprop(ctx, "result", inh.("result"))
    S.setprop(ctx, "response", inh.("response"))

    opname = H.or_(gp.("opname"), "")
    S.setprop(ctx, "op", resolve_op(ctx, opname))

    ctx
  end

  # Cache key is `<entity>:<opname>` so two entities sharing an op name get
  # distinct cached Operations.
  def resolve_op(ctx, opname) do
    entname = entity_name(S.getprop(ctx, "entity"))
    opmap = S.getprop(ctx, "opmap")
    cache_key = entname <> ":" <> opname

    cached = S.getprop(opmap, cache_key)

    cond do
      cached != nil ->
        cached

      opname == "" ->
        Operation.new(nil)

      true ->
        config = S.getprop(ctx, "config")
        opcfg = S.getpath(config, "entity." <> entname <> ".op." <> opname)
        inpt = if opname == "update" or opname == "create", do: "data", else: "match"

        points =
          if S.ismap(opcfg) do
            t = S.getprop(opcfg, "points")
            if S.islist(t), do: t, else: S.jt([])
          else
            S.jt([])
          end

        op =
          Operation.new(
            S.jm(["entity", entname, "name", opname, "input", inpt, "points", points])
          )

        S.setprop(opmap, cache_key, op)
        op
    end
  end
end
