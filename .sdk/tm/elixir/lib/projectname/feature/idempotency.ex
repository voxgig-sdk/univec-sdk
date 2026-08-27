# Univec SDK idempotency feature
#
# Idempotency keys for mutating operations. Adds an `Idempotency-Key` header
# (name configurable via `header`) to unsafe requests so a server can
# de-duplicate retried writes. The key is set once, at PreRequest, before the
# request is built — so it is stable across transport-level retries of the
# same call. A caller-supplied header is never overwritten (case-insensitive).
# The key generator (`keygen`) is injectable for deterministic tests.

defmodule Univec.Feature.Idempotency do
  alias Voxgig.Struct, as: S
  alias Univec.Feature, as: F

  def new do
    f = F.base("idempotency")
    F.install(f, "init", fn ctx, opts -> init(f, ctx, opts) end)
    F.install(f, "PreRequest", fn ctx -> pre_request(f, ctx) end)
    f
  end

  def init(f, ctx, options) do
    F.init_common(f, ctx, options)
    nil
  end

  defp pre_request(f, ctx) do
    if F.active?(f) do
      spec = S.getprop(ctx, "spec")

      if spec != nil and mutating(f, ctx) do
        header = por(S.getprop(F.opts(f), "header"), "Idempotency-Key")

        headers = S.getprop(spec, "headers")

        headers =
          if headers == nil do
            h = S.jm([])
            S.setprop(spec, "headers", h)
            h
          else
            headers
          end

        # Respect a key the caller already provided.
        if F.header_get(headers, header) == nil do
          key = genkey(f)
          S.setprop(headers, header, key)

          client = S.getprop(f, "client")
          track = F.track_node(client, "_idempotency", S.jm(["issued", 0, "last", nil]))
          S.setprop(track, "issued", S.getprop(track, "issued") + 1)
          S.setprop(track, "last", key)
        end
      end
    end

    nil
  end

  defp mutating(f, ctx) do
    opts = F.opts(f)
    methods = opt_list(S.getprop(opts, "methods"), ["POST", "PUT", "PATCH", "DELETE"])

    spec = S.getprop(ctx, "spec")

    method =
      if spec != nil and S.getprop(spec, "method") != nil do
        String.upcase(to_string(S.getprop(spec, "method")))
      else
        ""
      end

    if method != "" and method in methods do
      true
    else
      op = S.getprop(ctx, "op")
      opname = if op != nil, do: S.getprop(op, "name"), else: nil
      ops = opt_list(S.getprop(opts, "ops"), ["create", "update", "remove"])
      opname in ops
    end
  end

  defp genkey(f) do
    kg = S.getprop(F.opts(f), "keygen")

    if S.isfunc(kg) do
      kg.()
    else
      :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
    end
  end

  # Python `v or default`: falsy = nil, false, 0, 0.0, "".
  defp por(v, d) do
    if v == nil or v == false or v == 0 or v == "", do: d, else: v
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
