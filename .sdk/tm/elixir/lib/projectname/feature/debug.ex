# Univec SDK debug feature
#
# Request/response capture for debugging. Records a bounded ring buffer of
# per-operation traces — method, URL, redacted headers, response status and
# timing — on `client._debug["entries"]`. Sensitive header values (matching
# `redact`, default authorization/cookie/api-key style names) are masked.
# An optional `onEntry` callback receives each finished entry (e.g. to
# stream to a console). `max` caps the buffer (default 100).

defmodule Univec.Feature.Debug do
  alias Voxgig.Struct, as: S
  alias Univec.Helpers, as: H
  alias Univec.Feature, as: F

  def new do
    f = F.base("debug")
    F.install(f, "init", fn ctx, opts -> init(f, ctx, opts) end)
    F.install(f, "PreRequest", fn ctx -> pre_request(f, ctx) end)
    F.install(f, "PreResponse", fn ctx -> pre_response(f, ctx) end)
    F.install(f, "PreDone", fn ctx -> pre_done(f, ctx) end)
    F.install(f, "PreUnexpected", fn ctx -> pre_unexpected(f, ctx) end)
    f
  end

  def init(f, ctx, options) do
    F.init_common(f, ctx, options)

    client = S.getprop(f, "client")

    if S.getprop(client, "_debug") == nil do
      S.setprop(client, "_debug", S.jm(["entries", S.jt([])]))
    end

    nil
  end

  defp pre_request(f, ctx) do
    if not F.active?(f) do
      nil
    else
      spec = S.getprop(ctx, "spec")
      op = S.getprop(ctx, "op")

      opname =
        if op != nil do
          por(S.getprop(op, "entity"), "_") <> "." <> por(S.getprop(op, "name"), "_")
        else
          "_._"
        end

      entry =
        S.jm([
          "op", opname,
          "method", if(spec != nil, do: S.getprop(spec, "method"), else: nil),
          "url",
          if(spec != nil, do: H.or_(S.getprop(spec, "url"), S.getprop(spec, "path")), else: nil),
          "headers", redact(f, if(spec != nil, do: S.getprop(spec, "headers"), else: nil)),
          "start", F.now(f),
          "status", nil,
          "ok", nil,
          "durationMs", nil,
          "error", nil
        ])

      S.setprop(ctx, "_debug_entry", entry)
      nil
    end
  end

  defp pre_response(f, ctx) do
    if not F.active?(f) do
      nil
    else
      entry = S.getprop(ctx, "_debug_entry")

      if entry == nil do
        nil
      else
        response = S.getprop(ctx, "response")

        if response != nil do
          S.setprop(entry, "status", S.getprop(response, "status"))

          url = S.getprop(entry, "url")
          spec = S.getprop(ctx, "spec")

          if (url == nil or url == "") and spec != nil do
            S.setprop(entry, "url", S.getprop(spec, "url"))
          end
        end

        nil
      end
    end
  end

  defp pre_done(f, ctx) do
    if not F.active?(f) do
      nil
    else
      finish(f, ctx, true)
    end
  end

  defp pre_unexpected(f, ctx) do
    if not F.active?(f) do
      nil
    else
      entry = S.getprop(ctx, "_debug_entry")
      ctrl = S.getprop(ctx, "ctrl")

      if entry != nil and ctrl != nil do
        err = S.getprop(ctrl, "err")

        if err != nil do
          S.setprop(entry, "error", err_msg(err))
        end
      end

      finish(f, ctx, false)
    end
  end

  defp finish(f, ctx, ok) do
    entry = S.getprop(ctx, "_debug_entry")

    if entry == nil do
      nil
    else
      S.delprop(ctx, "_debug_entry")

      result = S.getprop(ctx, "result")
      S.setprop(entry, "ok", ok and (result == nil or S.getprop(result, "ok") != false))
      S.setprop(entry, "durationMs", max(0, F.now(f) - S.getprop(entry, "start")))

      if S.getprop(entry, "status") == nil and result != nil do
        S.setprop(entry, "status", S.getprop(result, "status"))
      end

      client = S.getprop(f, "client")
      buf = S.getprop(S.getprop(client, "_debug"), "entries")
      F.list_push(buf, entry)

      mx = case S.getprop(F.opts(f), "max") do nil -> 100; v -> v end
      trim_front(buf, mx)

      on_entry = S.getprop(F.opts(f), "onEntry")

      if S.isfunc(on_entry) do
        try do
          on_entry.(entry)
        rescue
          _ -> nil
        end
      end

      nil
    end
  end

  defp redact(f, headers) do
    if headers == nil do
      S.jm([])
    else
      patterns =
        opt_list(S.getprop(F.opts(f), "redact"), [
          "authorization",
          "cookie",
          "set-cookie",
          "api-key",
          "apikey",
          "x-api-key",
          "idempotency-key"
        ])

      out = S.jm([])

      Enum.each(H.entries(headers), fn {k, v} ->
        if String.downcase(to_string(k)) in patterns do
          S.setprop(out, k, "<redacted>")
        else
          S.setprop(out, k, v)
        end
      end)

      out
    end
  end

  # Python `getattr(err, "msg", None) or str(err)`.
  defp err_msg(err) do
    if match?(%Univec.Error{}, err) do
      por(err.msg, err_str(err))
    else
      err_str(err)
    end
  end

  defp err_str(e) do
    cond do
      is_exception(e) -> Exception.message(e)
      is_binary(e) -> e
      true -> S.stringify(e)
    end
  end

  # Python `while len(buf) > mx: buf.pop(0)` — drop from the front in place
  # (delprop on a list re-indexes, so the entries node reference is stable).
  defp trim_front(buf, mx) do
    if S.size(buf) > mx and S.size(buf) > 0 do
      S.delprop(buf, 0)
      trim_front(buf, mx)
    end

    nil
  end

  # Python `v or default`: falsy = nil, false, "".
  defp por(v, d) do
    if v == nil or v == false or v == "", do: d, else: v
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
