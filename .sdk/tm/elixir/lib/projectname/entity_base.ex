# Univec SDK generic entity behaviour
#
# Shared construction and data/match operations for every entity. The
# per-entity modules add the op functions (load/list/...) and pass their own
# module in so `make/1` can spawn a fresh instance. Construction and data
# hooks are fired directly (no jostraca marker needed — these are fixed).

defmodule Univec.EntityBase do
  alias Voxgig.Struct, as: S
  alias Univec.Helpers, as: H
  alias Univec.{Context, Utility, Pipeline}

  def construct(module, client, name, entopts \\ nil) do
    entopts = if S.ismap(entopts), do: entopts, else: S.jm([])

    if S.getprop(entopts, "active") == false do
      :ok
    else
      S.setprop(entopts, "active", true)
    end

    ent = S.jm([])
    S.setprop(ent, "_module", module)
    S.setprop(ent, "_name", name)
    S.setprop(ent, "_client", client)
    S.setprop(ent, "_utility", Univec.get_utility(client))
    S.setprop(ent, "_entopts", entopts)
    S.setprop(ent, "_data", S.jm([]))
    S.setprop(ent, "_match", S.jm([]))

    entctx =
      Context.new(S.jm(["entity", ent, "entopts", entopts]), Univec.get_root_ctx(client))

    S.setprop(ent, "_entctx", entctx)

    Utility.feature_hook(entctx, "PostConstructEntity")
    ent
  end

  def get_name(ent), do: S.getprop(ent, "_name")

  # Every operation resolves to the ENTITY, not the raw data — the record is
  # reached through data_get/1. `run_op` returns the terminal result value, so
  # the op hands that value back only when the pipeline FAILED (the error
  # shape is utility-configurable); on success it hands back the entity.
  # See AGENTS.md "Entity operations return ENTITIES".
  def op_return(ent, ctx, out) do
    result = S.getprop(ctx, "result")

    if result != nil and S.getprop(result, "ok") == true do
      ent
    else
      out
    end
  end

  # `remove` resolves to the entity, marked. The instance KEEPS the data it
  # held — a caller can still read what was deleted — but it is no longer a
  # live record.
  def mark_deleted(ent) do
    S.setprop(ent, "_deleted", true)
    ent
  end

  def deleted(ent), do: S.getprop(ent, "_deleted") == true


  def make(ent) do
    module = S.getprop(ent, "_module")
    client = S.getprop(ent, "_client")
    entopts0 = S.getprop(ent, "_entopts")
    opts = S.jm([])
    Enum.each(H.entries(entopts0), fn {k, v} -> S.setprop(opts, k, v) end)
    apply(module, :new, [client, opts])
  end

  def data_set(ent, args) do
    if args != nil do
      S.setprop(ent, "_data", H.or_(H.to_map(S.clone(args)), S.jm([])))
      Utility.feature_hook(S.getprop(ent, "_entctx"), "SetData")
    end

    ent
  end

  def data_get(ent) do
    Utility.feature_hook(S.getprop(ent, "_entctx"), "GetData")
    S.clone(S.getprop(ent, "_data"))
  end

  def match_set(ent, args) do
    if args != nil do
      S.setprop(ent, "_match", H.or_(H.to_map(S.clone(args)), S.jm([])))
      Utility.feature_hook(S.getprop(ent, "_entctx"), "SetMatch")
    end

    ent
  end

  def match_get(ent) do
    Utility.feature_hook(S.getprop(ent, "_entctx"), "GetMatch")
    S.clone(S.getprop(ent, "_match"))
  end

  # Streaming operation. Runs `action` (an op name, e.g. "list") through the
  # full pipeline and returns a lazy Elixir Stream of result items, so the
  # `streaming` feature's incremental output is reachable (a normal op call
  # materialises the whole result). When the streaming feature is active the
  # result carries a `stream` closure and this yields from it (honouring
  # chunkSize); otherwise it falls back to the materialised items, so stream
  # always yields. Records are unwrapped to bare struct maps (matching list).
  # `callopts` parameterises the call:
  #   - ctrl:   per-call pipeline control (threaded onto the op ctx);
  #   - body:   an enumerable/list payload for outbound (upload) streaming,
  #             attached to the request (reqdata.body$ + a stream_out marker);
  #   - signal: an optional 0-arity fn; when it returns true iteration stops.
  def stream(ent, action, args \\ nil, callopts \\ nil) do
    callopts = if S.ismap(callopts), do: callopts, else: S.jm([])
    ctrl = H.or_(H.to_map(S.getprop(callopts, "ctrl")), S.jm([]))
    S.setprop(ctrl, "stream", callopts)

    ctxmap =
      S.jm([
        "opname", action,
        "ctrl", ctrl,
        "match", S.getprop(ent, "_match"),
        "data", S.getprop(ent, "_data")
      ])

    am = H.to_map(args)
    if am != nil, do: Enum.each(H.entries(am), fn {k, v} -> S.setprop(ctxmap, k, v) end)

    ctx = Context.new(ctxmap, S.getprop(ent, "_entctx"))

    # Outbound: expose an enumerable/list payload so the request builder /
    # transport can stream it as the request body.
    body = S.getprop(callopts, "body")

    if body != nil do
      reqdata = H.or_(H.to_map(S.getprop(ctx, "reqdata")), S.jm([]))
      S.setprop(reqdata, "body$", body)
      S.setprop(ctx, "reqdata", reqdata)
      S.setprop(ctx, "stream_out", body)
    end

    Pipeline.run_op(ctx, fn -> nil end)

    result = S.getprop(ctx, "result")
    signal = S.getprop(callopts, "signal")
    stream_fn = if result != nil, do: S.getprop(result, "stream"), else: nil

    # Inbound: prefer the streaming feature's iterator; else fall back to the
    # materialised items so stream always yields.
    items =
      if S.isfunc(stream_fn) do
        stream_fn.()
      else
        rd = if result != nil, do: S.getprop(result, "resdata"), else: nil

        cond do
          S.islist(rd) -> Enum.map(0..(S.size(rd) - 1), fn i -> S.getelem(rd, i) end)
          rd == nil -> []
          true -> [rd]
        end
      end

    items
    |> Stream.take_while(fn _ -> not (S.isfunc(signal) and signal.() == true) end)
    |> Stream.map(&stream_unwrap/1)
  end

  # Unwrap an entity node to its bare record; recurse into chunk lists.
  defp stream_unwrap(item) do
    cond do
      S.ismap(item) and S.getprop(item, "_module") != nil -> data_get(item)
      is_list(item) -> Enum.map(item, &stream_unwrap/1)
      S.islist(item) -> Enum.map(0..(S.size(item) - 1), fn i -> stream_unwrap(S.getelem(item, i)) end)
      true -> item
    end
  end
end
