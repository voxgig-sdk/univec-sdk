# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (elixir/lib/voxgig_plugin/point.ex)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
defmodule Voxgig.Plugin.Point do
  @moduledoc """
  Extension points (section 6). Three kinds, chosen because they are what
  the two existing systems actually needed, and no more.

  A PLUGIN NEVER MUTATES THE HOST. That inversion is what makes
  deactivation possible: sdkgen's `utility.fetcher = wrapped` is not
  undoable, but "this instance holds slot 3 of the request chain" is
  undoable in O(1). OSGi named it the whiteboard pattern in 2004, in a
  paper called *Listeners Considered Harmful*, and for exactly this reason.
  """

  alias Voxgig.Plugin.Types

  @doc """
  Section 6.1: "fan-out" is not one answer but four. In a language with
  asynchrony, "call every binding" hides a decision - start them all and
  wait, await each in turn, or do not wait - and a design that leaves it
  unsaid gets four different answers from four ports, in the concurrency
  behaviour of production code no corpus entry happens to cover.

  ELIXIR IS THE PORT WHERE THAT IS LOUDEST: `Task.async_stream` is right
  there, and using it for `emit` would make every hook point concurrent and
  every ordering assertion a race. The host stays sequential (section 5.2)
  and the modes stay data.
  """
  def modes, do: ~w(emit parallel serial bail)

  @doc "Fan-out. Return values are ignored except in `bail`."
  def point_emit(bindings, "bail", arg) do
    # Stops at the first binding that RETURNS A VALUE - the "handled, stop"
    # case. A `nil` RETURN DECLINES (section 6.1): elixir has one way to
    # say nothing, and the model's rule is written to that rather than to
    # JavaScript's null/undefined pair. Not truthiness - `false` is a
    # value.
    Enum.reduce_while(bindings, nil, fn b, _ ->
      case b.fn.(nil, arg) do
        nil -> {:cont, nil}
        value -> {:halt, value}
      end
    end)
  end

  def point_emit(bindings, "emit", arg) do
    # `emit` raises synchronously; the collecting modes gather.
    Enum.each(bindings, fn b -> b.fn.(nil, arg) end)
    nil
  end

  def point_emit(bindings, _mode, arg) do
    Enum.reduce(bindings, [], fn b, errors ->
      try do
        b.fn.(nil, arg)
        errors
      rescue
        e -> errors ++ [Types.message(e)]
      end
    end)
  end

  @doc """
  Composition: b1(b2(b3(base))), FIRST BINDING OUTERMOST (section 6.2).

  Recomputed by the host whenever the live set changes, and cached between
  changes. Plugins receive `next` as an argument; they never see or store
  the previous value of anything. A plugin that stashes `next` and calls it
  after deactivation is a bug the host cannot prevent, and this says so
  rather than pretending otherwise.
  """
  def compose(bindings, base) do
    Enum.reduce(Enum.reverse(bindings), base, fn b, inner ->
      fn arg -> b.fn.(inner, arg) end
    end)
  end

  @doc """
  At most one live implementation (section 6.3). The winner is the highest
  band, ties broken by ref sort, and THE LOSERS ARE VISIBLE rather than
  silently ignored.
  """
  def point_provider([], _spec), do: %{winner: nil, shadowed: []}

  def point_provider(bindings, spec) do
    if Types.truthy(Types.get(spec, "exclusive")) and 1 < length(bindings) do
      refs = bindings |> Enum.map(& &1.ref) |> Enum.sort()

      Types.fail("plugin_point_exclusive",
                 "point is exclusive and has #{length(bindings)} bindings: " <>
                   Enum.join(refs, ", "),
                 %{"refs" => refs})
    end

    ranked = Types.stable_sort_by(bindings, fn b -> {-b.band, b.ref} end)
    %{winner: hd(ranked), shadowed: ranked |> tl() |> Enum.map(& &1.ref)}
  end
end
