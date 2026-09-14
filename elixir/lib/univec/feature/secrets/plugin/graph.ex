# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (elixir/lib/voxgig_plugin/graph.ex)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
defmodule Voxgig.Plugin.Graph do
  @moduledoc """
  Whole-graph resolution (section 11.4) - a phase, not a discovery.

  "Activate, and wait in `pending` if you must" is correct and, on its
  own, produces a terrible experience: apply twenty instances against a
  registry missing one thing and you get NINETEEN pending rows and no
  statement of what is actually wrong.

  `resolve_graph` is a PURE FUNCTION of the registry and the intended
  activation set. No callbacks run, no state changes, nothing is touched.
  It answers for the whole graph at once which instances can be live, and
  for each blocked one THE SPECIFIC REQUIREMENT that is unmet, and why.

  The failure mode being designed against is a famous one: OSGi's
  resolver is correct and its diagnostics are legendarily unusable. A
  resolver that says "blocked" without saying WHY has moved the problem
  rather than solved it, so `why` is part of the contract and the corpus
  pins its shape.
  """

  alias Voxgig.Plugin.Capability
  alias Voxgig.Plugin.Ref
  alias Voxgig.Plugin.Types
  alias Voxgig.Plugin.Version

  def resolve_graph(nodes) do
    byref = Map.new(nodes, &{Types.get(&1, "ref"), &1})

    resolved = fixedpoint(nodes, byref, MapSet.new())

    blocked =
      nodes
      |> Enum.reject(&MapSet.member?(resolved, Types.get(&1, "ref")))
      |> Enum.map(&{Types.get(&1, "ref"), firstunmet(&1, byref, resolved)})
      |> Enum.reject(&is_nil(elem(&1, 1)))
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    %{"resolved" => resolved |> MapSet.to_list() |> Enum.sort(), "blocked" => blocked}
  end

  # A node resolves when every mandatory requirement is met by an
  # ALREADY-RESOLVED provider. Iterating to a fixed point is what makes a
  # provider that is itself blocked propagate, rather than each node
  # being judged against the raw registry.
  defp fixedpoint(nodes, byref, resolved) do
    next =
      Enum.reduce(nodes, resolved, fn node, acc ->
        ref = Types.get(node, "ref")

        if MapSet.member?(acc, ref) or not is_nil(firstunmet(node, byref, acc)) do
          acc
        else
          MapSet.put(acc, ref)
        end
      end)

    if MapSet.size(next) == MapSet.size(resolved),
      do: resolved,
      else: fixedpoint(nodes, byref, next)
  end

  @doc """
  The FIRST unmet requirement, with the most specific explanation
  available. Order matters: "no provider at all" and "a provider at the
  wrong version" are different problems and a reader must not have to
  guess which they have.
  """
  def firstunmet(node, byref, resolved) do
    (Types.get(node, "requires") || [])
    |> Enum.reject(&Types.get(&1, "optional"))
    |> Enum.find_value(&unmet(node, &1, byref, resolved))
  end

  defp unmet(node, req, byref, resolved) do
    name = Types.get(req, "name")
    all = graph_candidates(byref, name)
    ok = Capability.resolve_capability(req, all)

    cond do
      all == [] ->
        why(node, name, %{"kind" => "absent"})

      ok == [] ->
        # Providers exist and none matched. Say which test failed.
        whynomatch(node, req, all) || why(node, name, %{"kind" => "absent"})

      Enum.any?(ok, &MapSet.member?(resolved, Types.get(&1, "ref"))) ->
        nil

      true ->
        # A provider exists and matches - but if none of them is itself
        # resolved, this node is blocked BEHIND it, and the chain is the
        # useful answer rather than "unmet".
        chain = ok |> Enum.map(&Types.get(&1, "ref")) |> Enum.sort()
        why(node, name, %{"kind" => "blocked", "chain" => chain})
    end
  end

  defp whynomatch(node, req, all) do
    range = Types.get(req, "range")
    match = Types.get(req, "match")
    bad = if is_nil(range), do: [], else: badversions(all, range)

    cond do
      [] != bad ->
        why(node, Types.get(req, "name"), %{
          "kind" => "version",
          "range" => range,
          "found" => Enum.sort(bad)
        })

      not is_nil(match) ->
        Enum.find_value(all, &badattr(node, req, match, &1))

      true ->
        nil
    end
  end

  defp badversions(all, range) do
    all
    |> Enum.map(&(Types.get(&1, "provides") |> Types.get("version")))
    |> Enum.filter(&(is_nil(&1) or not Version.satisfiesq(&1, range)))
    |> Enum.map(&(&1 || "(none)"))
  end

  defp badattr(node, req, match, cand) do
    attrs = Types.get(Types.get(cand, "provides"), "attrs") || %{}

    match
    |> Types.keys()
    |> Enum.find_value(fn k ->
      want = Types.get(match, k)

      if Types.has(attrs, k) and Capability.matchvalue(want, Types.get(attrs, k)) do
        nil
      else
        why(node, Types.get(req, "name"), %{
          "kind" => "match",
          "failing" => k,
          "want" => want,
          "found" => Types.get(attrs, k)
        })
      end
    end)
  end

  defp why(node, name, reason),
    do: %{"ref" => Types.get(node, "ref"), "unmet" => name, "why" => reason}

  def graph_candidates(byref, name) do
    # A NODE SATISFIES ITS OWN REF (section 11.1), and the graph learned
    # it here. Considering only declared capabilities made `resolve`
    # answer `absent` about a provider sitting right there and live -
    # section 11.4's job is explaining the graph the runtime reconciles,
    # and it was explaining a different one.
    asref = Ref.canon(name)

    byref
    |> Types.keys()
    |> Enum.flat_map(fn ref ->
      node = Types.get(byref, ref)

      # The ref match WINS OUTRIGHT for that node, as at runtime: one
      # candidate, not two, for a node both named `b` and providing `b`.
      if ref == asref do
        [%{"ref" => Types.get(node, "ref"), "pos" => Types.get(node, "pos") || 0,
           "provides" => %{"name" => name}}]
      else
        Types.get(node, "provides")
        |> Kernel.||([])
        |> Enum.filter(&(Types.get(&1, "name") == name))
        |> Enum.map(fn prov ->
          %{"ref" => Types.get(node, "ref"), "pos" => Types.get(node, "pos") || 0,
            "provides" => prov}
        end)
      end
    end)
  end
end
