# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (elixir/lib/voxgig_plugin/order.ex)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
defmodule Voxgig.Plugin.Order do
  @moduledoc """
  Ordering (section 7) - one rule, one place.

  sdkgen grew two special cases in `makeOptions` (`test`, then `station`)
  and the third was not far off. This sort is the whole replacement, and
  the tiers are in this order for a reason:

    1 constraints   before/after edges, by ref or by name
    2 bands         integer, lower first, default 0
    3 declaration   ties break by `pos`

  CONSTRAINTS BEAT BANDS precisely so the correct tool wins when both are
  present. A band expresses a genuine cross-cutting layer; a constraint
  expresses a relationship between two specific things; and a band chosen
  by trial and error to fix an ordering bug is a bug wearing a number.
  """

  alias Voxgig.Plugin.Ref
  alias Voxgig.Plugin.Types

  @doc """
  An integer, and only an integer: `true` and `"2"` are not bands, and
  elixir's `is_integer` excludes both.
  """
  def order_band(binding) do
    Types.asint(Types.get(binding.order || %{}, "band")) || 0
  end

  @doc """
  Was a constraint stated? An absent value and an EMPTY LIST are both
  no-constraint - and an empty list is TRUTHY in most languages, which is
  exactly how this class of bug survives a reading.
  """
  def order_declared(nil), do: false
  def order_declared(spec) when is_list(spec), do: Enum.any?(spec, &("" != &1))
  def order_declared(spec), do: "" != spec

  @doc """
  One spelling or a LIST of them. A list fans out to the UNION of what each
  names, so after: ['a','b'] means after BOTH, and the same instance named
  twice - once by name, once by ref - is one edge.
  """
  def order_targets(spec, nodes) do
    specs = if is_list(spec), do: spec, else: [spec]

    specs
    |> Enum.flat_map(fn one ->
      nodes
      |> Enum.filter(fn b -> b.ref == one or Ref.refname(b.ref) == one end)
      |> Enum.map(& &1.ref)
    end)
    |> Enum.uniq()
  end

  @doc """
  `bindings` is a list of `%{ref:, pos:, order:}` - an internal shape,
  never a corpus value.
  """
  def resolve_order(bindings, pin \\ nil) do
    byref = Map.new(bindings, fn b -> {b.ref, b} end)

    # Constraints are edges. A constraint naming an ABSENT binding is
    # satisfied VACUOUSLY (section 7) - a plugin ordered `after: 'test'`
    # must load in a host with no test plugin. That is sdkgen's __after__
    # behaviour, kept.
    edges =
      Enum.reduce(bindings, Map.new(bindings, fn b -> {b.ref, []} end), fn b, acc ->
        block = if is_map(b.order), do: b.order, else: %{}

        acc =
          if order_declared(Types.get(block, "after")) do
            Enum.reduce(order_targets(Types.get(block, "after"), bindings), acc, fn t, a ->
              Map.update!(a, t, &(&1 ++ [b.ref]))
            end)
          else
            acc
          end

        if order_declared(Types.get(block, "before")) do
          Map.update!(acc, b.ref, &(&1 ++ order_targets(Types.get(block, "before"), bindings)))
        else
          acc
        end
      end)

    indeg =
      Enum.reduce(edges, Map.new(bindings, fn b -> {b.ref, 0} end), fn {_from, tos}, acc ->
        Enum.reduce(tos, acc, fn to, a -> Map.update!(a, to, &(&1 + 1)) end)
      end)

    ready = Enum.filter(bindings, fn b -> 0 == Map.get(indeg, b.ref) end)
    out = walk(ready, indeg, edges, byref, [])

    if length(out) != length(bindings) do
      stuck = bindings |> Enum.reject(&(&1.ref in out)) |> Enum.map(& &1.ref)

      Types.fail("plugin_order_cycle",
                 "before/after constraints cycle: #{Enum.join(stuck, " -> ")}",
                 %{"cycle" => stuck})
    end

    applypin(out, edges, pin)
  end

  # Stable topological sort. Among ready nodes, band first (lower runs
  # first), then `pos` - the position the DOCUMENT visibly states, not the
  # order instances happened to load and not the incarnation `seq`.
  defp walk([], _indeg, _edges, _byref, out), do: Enum.reverse(out)

  defp walk(ready, indeg, edges, byref, out) do
    [nxt | rest] = Types.stable_sort_by(ready, fn b -> {order_band(b), b.pos} end)

    {indeg, added} =
      Enum.reduce(Map.get(edges, nxt.ref), {indeg, []}, fn to, {ind, acc} ->
        ind = Map.update!(ind, to, &(&1 - 1))
        if 0 == Map.get(ind, to), do: {ind, acc ++ [Map.get(byref, to)]}, else: {ind, acc}
      end)

    walk(rest ++ added, indeg, edges, byref, [nxt.ref | out])
  end

  @doc """
  A PIN IS NOT A CONSTRAINT (section 7).

  Constraints and bands are negotiable by definition - they are what
  plugins and documents say they want, and the sort's job is to satisfy
  them all. A pin is the host stating a structural invariant of its own
  architecture, which is a different kind of claim and must not lose a tie
  to a document.

  So a pin PLACES the binding at the named end, and an ordering that would
  move it away is `plugin_order_pinned` - rejected, not honoured into a
  broken wrap.
  """
  def applypin(order, _edges, nil), do: order

  def applypin(order, edges, pin) do
    # SORTED, not insertion order. A pin map is data - it can arrive from a
    # host's own construction options in any order, and two names pinned to
    # the same end are order-sensitive.
    out =
      Enum.reduce(Types.keys(pin), order, fn name, acc ->
        case Enum.find_index(acc, fn r -> Ref.refname(r) == name end) do
          nil ->
            acc

          idx ->
            # `first`/`outermost` is index 0; `last`/`innermost` is the
            # end. Section 6.2 makes the first chain binding outermost,
            # which is why the vocabulary is positional and why the two
            # spellings pair this way.
            ref = Enum.at(acc, idx)
            rest = List.delete_at(acc, idx)
            if Map.get(pin, name) in ["first", "outermost"], do: [ref | rest], else: rest ++ [ref]
        end
      end)

    # Now check that the placement did not break a constraint. This is the
    # half that makes a pin a rejection rather than an override: the host
    # wins on position, but it does not get to silently discard a
    # relationship a plugin declared.
    at = out |> Enum.with_index() |> Map.new()

    for from <- Enum.sort(Map.keys(edges)), to <- Map.get(edges, from) do
      if Map.get(at, from) > Map.get(at, to) do
        Types.fail("plugin_order_pinned",
                   "a pin would move a binding an ordering constrains: " <>
                     "#{from} must precede #{to}",
                   %{"before" => from, "after" => to})
      end
    end

    out
  end
end
