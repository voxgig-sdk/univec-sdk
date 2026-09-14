# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (elixir/lib/voxgig_plugin/capability.ex)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
defmodule Voxgig.Plugin.Capability do
  @moduledoc """
  Capabilities (section 11.1).

  A DEPENDENCY IS ON A CAPABILITY, NOT ON A REF - because it is a
  dependency on something that can do the job, and which instance is doing
  it is exactly the configuration detail a plugin must not care about.

  But A BINDING IS TO AN INSTANCE, not to a capability, which is what
  decides behaviour when the bound provider leaves while another match
  remains.
  """

  alias Voxgig.Plugin.Types
  alias Voxgig.Plugin.Version

  @doc """
  Rank the matching live providers and return them best-first: highest
  `version`, then LOWEST `priority` (default 0), then declaration position
  `pos` ascending.

  `priority` is a field on the capability rather than section 7's `order`
  band, because bands live on POINT BINDINGS: a provider may have several
  bindings with different bands, or none at all, so a rank reaching for one
  would be undefined in the common case.

  Without a total rank, "any provider satisfies" is true of the GRAPH and
  useless to the PLUGIN - two ports could bind different `store` instances,
  both resolve green, and behave differently, which is precisely the
  divergence a shared corpus exists to catch.
  """
  def resolve_capability(req, candidates) do
    candidates
    |> Enum.filter(&matches(req, Types.get(&1, "provides") || %{}))
    |> Types.stable_sort_by(&rank_key/1)
  end

  @doc """
  An ABSENT version sorts LAST, whatever the other is - "no version" loses
  to every version rather than being read as 0.0.0. The leading flag is
  what expresses that in a sort KEY rather than a comparator.
  """
  def rank_key(cand) do
    prov = Types.get(cand, "provides") || %{}
    version = Types.get(prov, "version")

    parts =
      case version do
        nil -> [0, 0, 0]
        text -> text |> Version.version_parts() |> Enum.map(&(-&1))
      end

    {if(is_nil(version), do: 1, else: 0), parts, Types.get(prov, "priority") || 0,
     Types.get(cand, "pos") || 0}
  end

  def matches(req, prov) do
    cond do
      Types.get(req, "name") != Types.get(prov, "name") ->
        false

      not is_nil(Types.get(req, "range")) and
          (is_nil(Types.get(prov, "version")) or
             not Version.satisfiesq(Types.get(prov, "version"), Types.get(req, "range"))) ->
        false

      true ->
        # `match` is checked against the provider's `attrs`, key by key. A
        # key the provider does not carry is a miss, not a pass: a
        # requirement asking for `transactional: true` must not be
        # satisfied by a provider that never said.
        want = Types.get(req, "match")

        if is_nil(want) do
          true
        else
          attrs = Types.get(prov, "attrs") || %{}

          Enum.all?(Types.keys(want), fn k ->
            Types.has(attrs, k) and matchvalue(Map.get(want, k), Map.get(attrs, k))
          end)
        end
    end
  end

  @doc """
  PARTIAL MATCH, RECURSING INTO MAPS (section 11.1).

  Section 11.1 defines `match` as "a partial match against `attrs`, with
  exactly the semantics voxgig/struct and the omni corpus already define
  for `match` - every leaf in the requirement must be present and equal in
  the capability, keys not mentioned are not checked."

  Equality is by JSON TYPE as well as value: `transactional: 1` does not
  satisfy `transactional: true`. ELIXIR NEEDS NO GUARD FOR THAT - `true ==
  1` and `"1" == 1` are both false, while `1 == 1.0` is true, which is
  exactly JSON's rule - so the explicit check php, perl and lua each carry
  would be dead code here.

  A LIST IS COMPARED LEAF-WISE AT THE SAME LENGTH, not as a subset.
  """
  def matchvalue(want, got) when is_map(want) do
    is_map(got) and
      Enum.all?(Types.keys(want), fn k ->
        Types.has(got, k) and matchvalue(Map.get(want, k), Map.get(got, k))
      end)
  end

  def matchvalue(want, got) when is_list(want) do
    is_list(got) and length(want) == length(got) and
      want |> Enum.zip(got) |> Enum.all?(fn {w, g} -> matchvalue(w, g) end)
  end

  def matchvalue(want, got), do: Types.same(want, got)
end
