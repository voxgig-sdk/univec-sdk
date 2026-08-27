# Univec SDK audit feature
#
# Audit trail. Emits a structured record for every operation — who (actor),
# what (entity + op), the outcome, and a correlation id — suitable for
# compliance logging. Records accumulate on `client._audit["records"]`
# (bounded by `max`, default 1000) and, when a `sink` callback is supplied,
# are also pushed to it (e.g. to forward to a SIEM). The actor is taken
# from a per-call `ctrl` actor, then options (`actor`), then 'anonymous'.
# Timestamps use the injectable `now` clock so tests stay deterministic.

defmodule Univec.Feature.Audit do
  alias Voxgig.Struct, as: S
  alias Univec.Feature

  def new do
    f = Feature.base("audit")
    Feature.install(f, "init", fn ctx, opts -> init(f, ctx, opts) end)
    Feature.install(f, "PreDone", fn ctx -> pre_done(f, ctx) end)
    Feature.install(f, "PreUnexpected", fn ctx -> pre_unexpected(f, ctx) end)
    f
  end

  def init(f, ctx, options) do
    Feature.init_common(f, ctx, options)
    S.setprop(f, "seq", 0)

    client = S.getprop(f, "client")

    if S.getprop(client, "_audit") == nil do
      S.setprop(client, "_audit", S.jm(["records", S.jt([])]))
    end

    nil
  end

  # Outcome reflects the actual result; a non-2xx reaches PreDone before the
  # pipeline raises.
  defp pre_done(f, ctx) do
    if Feature.active?(f) do
      result = S.getprop(ctx, "result")
      ok = result != nil and S.getprop(result, "ok") != false and S.getprop(result, "err") == nil
      emit(f, ctx, if(ok, do: "ok", else: "error"))
    end

    nil
  end

  defp pre_unexpected(f, ctx) do
    if Feature.active?(f), do: emit(f, ctx, "error")
    nil
  end

  defp emit(f, ctx, outcome) do
    # One record per operation (PreDone + a following PreUnexpected on a
    # non-2xx must not double-log).
    if S.getprop(ctx, "_audit_seen") == true do
      nil
    else
      S.setprop(ctx, "_audit_seen", true)

      seq = S.getprop(f, "seq") + 1
      S.setprop(f, "seq", seq)

      opts = Feature.opts(f)

      ctrl = S.getprop(ctx, "ctrl")
      actor = if ctrl != nil, do: S.getprop(ctrl, "actor"), else: nil
      actor = if actor == nil, do: S.getprop(opts, "actor"), else: actor
      actor = if actor == nil, do: "anonymous", else: actor

      op = S.getprop(ctx, "op")
      entity_v = or_underscore(if op != nil, do: S.getprop(op, "entity"), else: nil)
      opname = or_underscore(if op != nil, do: S.getprop(op, "name"), else: nil)

      result = S.getprop(ctx, "result")
      status = if result != nil, do: S.getprop(result, "status"), else: nil

      record =
        S.jm([
          "seq", seq,
          "ts", Feature.now(f),
          "actor", actor,
          "entity", entity_v,
          "op", opname,
          "outcome", outcome,
          "status", status,
          "correlationId", S.getprop(ctx, "id")
        ])

      client = S.getprop(f, "client")
      records = S.getprop(S.getprop(client, "_audit"), "records")
      Feature.list_push(records, record)

      mxv = S.getprop(opts, "max")
      mx = if mxv == nil, do: 1000, else: mxv
      trim(records, mx)

      sink = S.getprop(opts, "sink")

      if S.isfunc(sink) do
        try do
          sink.(record)
        rescue
          _ -> nil
        catch
          _, _ -> nil
        end
      end

      nil
    end
  end

  # Mirrors Python `x or "_"`: empty string / nil / false collapse to "_".
  defp or_underscore(v) do
    if v == nil or v == false or v == "", do: "_", else: v
  end

  defp trim(records, mx) do
    if S.size(records) > mx do
      S.delprop(records, 0)
      trim(records, mx)
    end
  end
end
