# Univec SDK telemetry feature
#
# Distributed-tracing telemetry. Opens a span per operation (PrePoint),
# propagates trace context to the server as W3C `traceparent` plus
# `X-Trace-Id` / `X-Span-Id` headers (PreRequest), and closes the span on
# completion (PreDone) or failure (PreUnexpected). Finished spans are kept
# on `client._telemetry["spans"]`; an `exporter` callback, when provided,
# is invoked with each finished span. Trace/span id generation (`idgen`)
# and the clock (`now`) are injectable for deterministic tests.

defmodule Univec.Feature.Telemetry do
  alias Voxgig.Struct, as: S
  alias Univec.Helpers, as: H
  alias Univec.Feature, as: F

  def new do
    f = F.base("telemetry")
    F.install(f, "init", fn ctx, opts -> init(f, ctx, opts) end)
    F.install(f, "PrePoint", fn ctx -> pre_point(f, ctx) end)
    F.install(f, "PreRequest", fn ctx -> pre_request(f, ctx) end)
    F.install(f, "PreDone", fn ctx -> pre_done(f, ctx) end)
    F.install(f, "PreUnexpected", fn ctx -> pre_unexpected(f, ctx) end)
    f
  end

  def init(f, ctx, options) do
    F.init_common(f, ctx, options)
    S.setprop(f, "seq", 0)

    client = S.getprop(f, "client")

    if S.getprop(client, "_telemetry") == nil do
      S.setprop(client, "_telemetry", S.jm(["spans", S.jt([]), "active", 0]))
    end

    nil
  end

  defp pre_point(f, ctx) do
    if not F.active?(f) do
      nil
    else
      op = S.getprop(ctx, "op")

      {entity, opname} =
        if op != nil do
          {por(S.getprop(op, "entity"), "_"), por(S.getprop(op, "name"), "_")}
        else
          {"_", "_"}
        end

      span =
        S.jm([
          "traceId", gen_id(f, "trace"),
          "spanId", gen_id(f, "span"),
          "name", entity <> "." <> opname,
          "start", F.now(f),
          "end", nil,
          "durationMs", nil,
          "ok", nil
        ])

      S.setprop(ctx, "_telemetry_span", span)

      telemetry = S.getprop(S.getprop(f, "client"), "_telemetry")
      S.setprop(telemetry, "active", S.getprop(telemetry, "active") + 1)
      nil
    end
  end

  defp pre_request(f, ctx) do
    if not F.active?(f) do
      nil
    else
      span = S.getprop(ctx, "_telemetry_span")
      spec = S.getprop(ctx, "spec")

      if span == nil or spec == nil do
        nil
      else
        if S.getprop(spec, "headers") == nil do
          S.setprop(spec, "headers", S.jm([]))
        end

        headers = S.getprop(spec, "headers")
        hopt = H.or_(H.to_map(S.getprop(F.opts(f), "headers")), S.jm([]))

        S.setprop(headers, por(S.getprop(hopt, "trace"), "X-Trace-Id"), S.getprop(span, "traceId"))
        S.setprop(headers, por(S.getprop(hopt, "span"), "X-Span-Id"), S.getprop(span, "spanId"))

        S.setprop(
          headers,
          por(S.getprop(hopt, "parent"), "traceparent"),
          "00-" <> S.getprop(span, "traceId") <> "-" <> S.getprop(span, "spanId") <> "-01"
        )

        nil
      end
    end
  end

  defp pre_done(f, ctx) do
    if not F.active?(f) do
      nil
    else
      result = S.getprop(ctx, "result")
      ok = result != nil and S.getprop(result, "ok") != false and S.getprop(result, "err") == nil
      close(f, ctx, ok)
    end
  end

  defp pre_unexpected(f, ctx) do
    if not F.active?(f) do
      nil
    else
      close(f, ctx, false)
    end
  end

  # Close once per operation; a PreDone followed by a pipeline raise (non-2xx)
  # fires PreUnexpected too, which then finds no open span.
  defp close(f, ctx, ok) do
    span = S.getprop(ctx, "_telemetry_span")

    if span == nil do
      nil
    else
      S.delprop(ctx, "_telemetry_span")

      fin = F.now(f)
      S.setprop(span, "end", fin)
      S.setprop(span, "durationMs", max(0, fin - S.getprop(span, "start")))
      S.setprop(span, "ok", ok)

      telemetry = S.getprop(S.getprop(f, "client"), "_telemetry")
      S.setprop(telemetry, "active", S.getprop(telemetry, "active") - 1)
      F.list_push(S.getprop(telemetry, "spans"), span)

      exporter = S.getprop(F.opts(f), "exporter")

      if S.isfunc(exporter) do
        try do
          exporter.(span)
        rescue
          _ -> nil
        end
      end

      nil
    end
  end

  defp gen_id(f, kind) do
    idgen = S.getprop(F.opts(f), "idgen")

    if S.isfunc(idgen) do
      idgen.(kind)
    else
      # Deterministic-ish sequential id; unique within a client instance.
      seq = S.getprop(f, "seq") + 1
      S.setprop(f, "seq", seq)
      n = seq |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")
      prefix = if kind == "trace", do: "t", else: "s"
      prefix <> String.pad_trailing(n, 16, "0")
    end
  end

  # Python `v or default`: falsy = nil, false, "".
  defp por(v, d) do
    if v == nil or v == false or v == "", do: d, else: v
  end
end
