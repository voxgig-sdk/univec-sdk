# Univec SDK rbac feature
#
# Client-side role/permission enforcement. Before an operation resolves its
# endpoint, the required permission for that entity+operation is checked
# against the permissions the client holds; a disallowed call is
# short-circuited with an `rbac_denied` error placed in ctx.out["point"]
# (the pipeline's make_point surfaces it) and never touches the network.
# Required permissions come from `rules` (keyed by `<entity>.<op>`, `<op>`,
# or `*`); the default when no rule matches is controlled by `deny`
# (default: allow when unspecified). Held permissions are the `permissions`
# list (a `*` grants everything).

defmodule Univec.Feature.Rbac do
  alias Voxgig.Struct, as: S
  alias Univec.{Feature, Context}

  def new do
    f = Feature.base("rbac")
    Feature.install(f, "init", fn ctx, opts -> init(f, ctx, opts) end)
    Feature.install(f, "PrePoint", fn ctx -> pre_point(f, ctx) end)
    f
  end

  def init(f, ctx, options) do
    Feature.init_common(f, ctx, options)

    opts = Feature.opts(f)
    granted = S.jm([])
    perms = S.getprop(opts, "permissions")

    if S.islist(perms) do
      n = S.size(perms)

      if n > 0 do
        Enum.each(0..(n - 1), fn i ->
          perm = S.getelem(perms, i)
          S.setprop(granted, perm, true)
        end)
      end
    end

    S.setprop(f, "granted", granted)
    nil
  end

  defp pre_point(f, ctx) do
    if Feature.active?(f) do
      required = required(f, ctx)

      cond do
        required == nil ->
          # No rule: honour the default policy.
          if S.getprop(Feature.opts(f), "deny") == true do
            reject(f, ctx, "<default-deny>")
          end

          nil

        true ->
          granted = S.getprop(f, "granted")

          if S.getprop(granted, "*") == true or S.getprop(granted, required) == true do
            track(f, ctx, required, true)
          else
            reject(f, ctx, required)
          end
      end
    end

    nil
  end

  defp required(f, ctx) do
    rules = S.getprop(Feature.opts(f), "rules")
    rules = if S.ismap(rules), do: rules, else: S.jm([])

    entity = entity_of(ctx)
    opname = opname_of(ctx)
    key = entity <> "." <> opname

    cond do
      S.getprop(rules, key) != nil -> S.getprop(rules, key)
      S.getprop(rules, opname) != nil -> S.getprop(rules, opname)
      S.getprop(rules, "*") != nil -> S.getprop(rules, "*")
      true -> nil
    end
  end

  defp entity_of(ctx) do
    name = Context.entity_name(S.getprop(ctx, "entity"))
    name = if name == "_", do: "", else: name

    if name == "" do
      op = S.getprop(ctx, "op")
      oe = if op != nil, do: S.getprop(op, "entity"), else: nil
      if is_binary(oe), do: oe, else: ""
    else
      name
    end
  end

  defp opname_of(ctx) do
    op = S.getprop(ctx, "op")
    nm = if op != nil, do: S.getprop(op, "name"), else: nil
    if is_binary(nm), do: nm, else: ""
  end

  defp reject(f, ctx, required) do
    track(f, ctx, required, false)

    op = S.getprop(ctx, "op")
    nm = if op != nil, do: S.getprop(op, "name"), else: nil
    opname = if is_binary(nm) and nm != "", do: nm, else: "?"

    err =
      Context.make_error(
        ctx,
        "rbac_denied",
        "Permission \"" <> to_string(required) <> "\" required for operation \"" <> opname <> "\""
      )

    # Short-circuit endpoint resolution; the pipeline surfaces this error.
    S.setprop(S.getprop(ctx, "out"), "point", err)
    err
  end

  defp track(f, ctx, required, allowed) do
    client = S.getprop(f, "client")
    t = Feature.track_node(client, "_rbac", S.jm(["allowed", 0, "denied", 0, "last", nil]))

    key = if allowed, do: "allowed", else: "denied"
    S.setprop(t, key, S.getprop(t, key) + 1)

    op = S.getprop(ctx, "op")
    opname = if op != nil, do: S.getprop(op, "name"), else: nil
    S.setprop(t, "last", S.jm(["required", required, "allowed", allowed, "op", opname]))
    nil
  end
end
