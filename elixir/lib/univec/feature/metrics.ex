# Univec SDK metrics feature
#
# Statistics capture. Records per-operation counters and latency for every
# call: totals plus a breakdown keyed by `<entity>.<op>`. Timing starts at
# endpoint resolution (PrePoint) and stops when the call returns (PreDone)
# or fails (PreUnexpected). Aggregates live on `client._metrics`. The clock
# is injectable (`now`) for deterministic tests.

defmodule Univec.Feature.Metrics do
  alias Voxgig.Struct, as: S
  alias Univec.Feature, as: F

  def new do
    f = F.base("metrics")
    F.install(f, "init", fn ctx, opts -> init(f, ctx, opts) end)
    F.install(f, "PrePoint", fn ctx -> pre_point(f, ctx) end)
    F.install(f, "PreDone", fn ctx -> pre_done(f, ctx) end)
    F.install(f, "PreUnexpected", fn ctx -> pre_unexpected(f, ctx) end)
    f
  end

  def init(f, ctx, options) do
    F.init_common(f, ctx, options)

    client = S.getprop(f, "client")

    if S.getprop(client, "_metrics") == nil do
      S.setprop(
        client,
        "_metrics",
        S.jm([
          "total", S.jm(["count", 0, "ok", 0, "err", 0, "totalMs", 0, "maxMs", 0]),
          "ops", S.jm([])
        ])
      )
    end

    nil
  end

  defp pre_point(f, ctx) do
    if not F.active?(f) do
      nil
    else
      S.setprop(ctx, "_metrics_start", F.now(f))
      nil
    end
  end

  defp pre_done(f, ctx) do
    if not F.active?(f) do
      nil
    else
      # Classify by the actual result: a 4xx/5xx that flows through still
      # reaches PreDone before the pipeline raises.
      result = S.getprop(ctx, "result")
      ok = result != nil and S.getprop(result, "ok") != false and S.getprop(result, "err") == nil
      record(f, ctx, ok)
    end
  end

  defp pre_unexpected(f, ctx) do
    if not F.active?(f) do
      nil
    else
      record(f, ctx, false)
    end
  end

  # Record once per operation. When a non-2xx result reaches PreDone the
  # pipeline then raises, firing PreUnexpected too; the missing start marker
  # makes the second call a no-op.
  defp record(f, ctx, ok) do
    start = S.getprop(ctx, "_metrics_start")

    if start == nil do
      nil
    else
      S.delprop(ctx, "_metrics_start")

      dur = max(0, F.now(f) - start)

      metrics = S.getprop(S.getprop(f, "client"), "_metrics")
      op = S.getprop(ctx, "op")

      key =
        if op != nil do
          por(S.getprop(op, "entity"), "_") <> "." <> por(S.getprop(op, "name"), "_")
        else
          "_"
        end

      ops = S.getprop(metrics, "ops")
      op_bucket = S.getprop(ops, key)

      op_bucket =
        if op_bucket == nil do
          b = S.jm(["count", 0, "ok", 0, "err", 0, "totalMs", 0, "maxMs", 0])
          S.setprop(ops, key, b)
          b
        else
          op_bucket
        end

      bump(S.getprop(metrics, "total"), ok, dur)
      bump(op_bucket, ok, dur)
      nil
    end
  end

  defp bump(bucket, ok, dur) do
    S.setprop(bucket, "count", S.getprop(bucket, "count") + 1)

    ok_key = if ok, do: "ok", else: "err"
    S.setprop(bucket, ok_key, S.getprop(bucket, ok_key) + 1)

    S.setprop(bucket, "totalMs", S.getprop(bucket, "totalMs") + dur)

    if dur > S.getprop(bucket, "maxMs") do
      S.setprop(bucket, "maxMs", dur)
    end

    nil
  end

  # Python `v or default`: falsy = nil, false, "".
  defp por(v, d) do
    if v == nil or v == false or v == "", do: d, else: v
  end
end
