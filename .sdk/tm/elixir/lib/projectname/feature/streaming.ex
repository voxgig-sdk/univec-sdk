# Univec SDK streaming feature
#
# Streaming result support. For list-style operations it attaches a
# `result.stream()` closure so callers can consume items incrementally
# instead of materialising the whole list. The closure reads the result's
# data lazily (so it reflects the parsed entities). A `chunkDelay` (ms)
# simulates paced/chunked delivery for offline tests via the injectable
# `sleep`; a `chunkSize` groups items into batches when set.
#
# Elixir has no generators, so the donor's `_iterate` generator becomes a
# 0-arity closure that returns a plain Elixir list — a flat list of items,
# or (when chunkSize is set) a list of chunk-lists. Because a list must be
# materialised eagerly, any `chunkDelay` sleeps happen when `stream()` is
# called rather than lazily per consumed item; that is the faithful
# translation of the paced generator.

defmodule Univec.Feature.Streaming do
  alias Voxgig.Struct, as: S
  alias Univec.Helpers, as: H
  alias Univec.Feature, as: F

  def new do
    f = F.base("streaming")
    F.install(f, "init", fn ctx, opts -> init(f, ctx, opts) end)
    F.install(f, "PreResult", fn ctx -> pre_result(f, ctx) end)
    f
  end

  def init(f, ctx, options) do
    F.init_common(f, ctx, options)
    nil
  end

  defp pre_result(f, ctx) do
    if not F.active?(f) do
      nil
    else
      if not streamable?(f, ctx) do
        nil
      else
        result = S.getprop(ctx, "result")

        if result == nil do
          nil
        else
          S.setprop(result, "streaming", true)
          S.setprop(result, "stream", fn -> stream_items(f, result) end)

          client = S.getprop(f, "client")
          track = F.track_node(client, "_streaming", S.jm(["opened", 0]))
          S.setprop(track, "opened", S.getprop(track, "opened") + 1)
          nil
        end
      end
    end
  end

  # Produce the streamed items eagerly as a plain Elixir list.
  defp stream_items(f, result) do
    opts = F.opts(f)
    chunk_delay = H.or_(S.getprop(opts, "chunkDelay"), 0)
    chunk_size = H.or_(S.getprop(opts, "chunkSize"), 0)

    # Read lazily so downstream result processing is reflected.
    v = S.getprop(result, "resdata")
    items = if S.islist(v), do: opt_list(v, []), else: []

    if is_number(chunk_size) and not is_boolean(chunk_size) and chunk_size > 0 do
      items
      |> Enum.chunk_every(chunk_size)
      |> Enum.map(fn chunk ->
        maybe_sleep(f, chunk_delay)
        chunk
      end)
    else
      Enum.map(items, fn item ->
        maybe_sleep(f, chunk_delay)
        item
      end)
    end
  end

  defp maybe_sleep(f, chunk_delay) do
    if is_number(chunk_delay) and not is_boolean(chunk_delay) and chunk_delay > 0 do
      F.sleep(f, chunk_delay)
    end

    nil
  end

  defp streamable?(f, ctx) do
    ops = opt_list(S.getprop(F.opts(f), "ops"), ["list"])
    op = S.getprop(ctx, "op")
    opname = if op != nil, do: S.getprop(op, "name"), else: nil
    opname in ops
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
