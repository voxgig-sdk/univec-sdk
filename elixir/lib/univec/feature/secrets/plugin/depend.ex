# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (elixir/lib/voxgig_plugin/depend.ex)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
defmodule Voxgig.Plugin.Depend do
  @moduledoc """
  Dependency cardinality, policy, and the restart graph (section 11.3).

  TWO AXES, BOTH DECLARED BY THE DEFINITION THAT HAS THE REQUIREMENT,
  because only it knows what it can cope with: a mandatory-static
  requirement gates activation and restarts on loss; a mandatory-dynamic
  one gates but survives a swap; an optional-static one never gates but
  restarts on a change; an optional-dynamic one is a notification and
  nothing else.

  `dynamic` means the plugin has said, IN WRITING, that it can survive its
  provider being swapped underneath it. It is not the default because most
  plugins cannot, and the cost of wrongly assuming they can is a live
  instance holding a dead reference.
  """

  alias Voxgig.Plugin.Ref
  alias Voxgig.Plugin.Types

  @doc "A bare string is shorthand for `{name}`."
  def normrequire(raw) when is_binary(raw), do: %{"name" => raw}
  def normrequire(raw) when is_map(raw), do: raw
  def normrequire(_), do: %{}

  @doc """
  The requirements a definition declared, normalized.

  BOTH AXES ARE READ AT TWO LEVELS, AND THE PER-REQUIREMENT ONE WINS.
  `optional` unions rather than overriding - both spellings are statements
  that this requirement need not gate activation, and there is no reading
  under which one of them means "actually, mandatory".
  """
  def requirements(options) do
    raw = Types.get(options, "requires") || []
    marked = Types.get(options, "optional")
    fallback = Types.get(options, "policy")

    Enum.map(raw, fn item ->
      req = normrequire(item)
      ismarked = is_list(marked) and Types.get(req, "name") in marked

      req =
        if Types.truthy(Types.get(req, "optional")) or ismarked do
          Map.put(req, "optional", true)
        else
          req
        end

      if is_nil(Types.get(req, "policy")) and not is_nil(fallback) do
        Map.put(req, "policy", fallback)
      else
        req
      end
    end)
  end

  @doc """
  Does losing this requirement's SELECTED provider restart the consumer?
  The mandatory ones under `static`, and the `static` optional ones - both
  make a capability change deactivate and reactivate. `dynamic` never
  restarts.
  """
  def restartsonloss(req), do: "dynamic" != (Types.get(req, "policy") || "static")

  @doc """
  Does an unmet requirement keep the consumer out of `live`?

  Cardinality alone decides this, NOT policy. `dynamic` is a statement
  about surviving a SWAP, not about starting without the thing at all - a
  mandatory-dynamic consumer still waits in `pending` for its first
  provider.
  """
  def gatesactivation(req), do: true != Types.get(req, "optional")

  @doc """
  Edges that can cause a restart, which is exactly the set a cycle must be
  detected over (section 11.3). ONLY `dynamic` OPTIONAL EDGES ARE EXCLUDED
  - an earlier draft excluded EVERY optional edge and thereby admitted the
  non-terminating case it was trying to permit.
  """
  def restartcausing(req), do: gatesactivation(req) or restartsonloss(req)

  @doc """
  A cycle through restart-causing requirements is
  `plugin_dependency_cycle`, detected AT LOAD - before anything runs,
  because the failure it describes is a non-terminating reconcile and the
  only safe time to report that is before it starts.

  The graph is over capabilities, not refs: an edge runs from a consumer to
  EVERY node that provides what it needs, because any of them could be the
  one selected and a cycle through any is a cycle. A node also satisfies
  its own name as a ref (section 11.1), which is why the ref is a provider
  of itself here.

  `nodes` is a list of `%{ref:, provides:, requires:}`.
  """
  def dependencycycle(nodes) do
    # TWO INDEXES, NOT ONE MERGED MAP. Capability names and refs are
    # matched differently - a capability by its exact name, a ref through
    # the canonical spelling (section 4 rule 5) - and one map keyed by
    # both can only do one of them. Keyed by both and looked up raw, as
    # this was, a cycle spelled `a$`/`b$` found no providers and EVADED
    # the load-time check that exists to catch a non-terminating
    # reconcile.
    bycap =
      Enum.reduce(nodes, %{}, fn n, acc ->
        Enum.reduce(n.provides, acc, fn cap, a ->
          Map.update(a, cap, [n.ref], &(&1 ++ [n.ref]))
        end)
      end)

    isref = MapSet.new(nodes, & &1.ref)

    edges =
      Map.new(nodes, fn n ->
        outs =
          n.requires
          |> Enum.filter(&restartcausing/1)
          |> Enum.flat_map(fn req ->
            reqname = Types.get(req, "name")
            from = Map.get(bycap, reqname) || []
            # A node satisfies its own name AS A REF (section 11.1),
            # canonically - exactly what `providersof` does at runtime.
            # `canon` hands back a name no ref could have unchanged, and
            # no instance ref can equal one, so it is the tolerant test.
            asref = Ref.canon(reqname)
            if MapSet.member?(isref, asref), do: from ++ [asref], else: from
          end)
          |> Enum.reject(&(&1 == n.ref))
          |> Enum.uniq()
          |> Enum.sort()

        {n.ref, outs}
      end)

    # Iterative DFS with an explicit stack: twenty ports, and several of
    # them have no recursion budget worth relying on. Elixir's stack is
    # fine, but the shape stays the same so the ports read alike.
    colour = Map.new(nodes, fn n -> {n.ref, :white} end)
    starts = edges |> Map.keys() |> Enum.sort()
    Enum.reduce_while(starts, nil, fn start, _ ->
      case dfs(start, edges, colour) do
        {:cycle, cycle} -> {:halt, cycle}
        {:done, colour} -> {:cont, colour} |> then(fn {_, c} -> {:cont, c} end)
      end
    end)
    |> case do
      cycle when is_list(cycle) -> cycle
      _ -> nil
    end
  end

  defp dfs(start, edges, colour) do
    if :white != Map.get(colour, start) do
      {:done, colour}
    else
      walk([{start, 0}], [start], Map.put(colour, start, :grey), edges)
    end
  end

  defp walk([], _path, colour, _edges), do: {:done, colour}

  defp walk([{node, index} | rest], path, colour, edges) do
    outs = Map.get(edges, node)

    if index >= length(outs) do
      walk(rest, Enum.drop(path, -1), Map.put(colour, node, :black), edges)
    else
      nxt = Enum.at(outs, index)
      stack = [{node, index + 1} | rest]

      case Map.get(colour, nxt) do
        :grey ->
          # Report the cycle itself, not the walk that found it.
          at = Enum.find_index(path, &(&1 == nxt))
          {:cycle, Enum.drop(path, at) ++ [nxt]}

        :black ->
          walk(stack, path, colour, edges)

        _ ->
          walk([{nxt, 0} | stack], path ++ [nxt], Map.put(colour, nxt, :grey), edges)
      end
    end
  end

  @doc """
  Raise on a cycle, naming it. Separate from the detector so the detector
  stays pure and corpus-testable.
  """
  def checkcycle(nodes) do
    case dependencycycle(nodes) do
      nil ->
        :ok

      cycle ->
        Types.fail("plugin_dependency_cycle",
                   "requirements cycle: #{Enum.join(cycle, " -> ")}", %{"cycle" => cycle})
    end
  end
end
