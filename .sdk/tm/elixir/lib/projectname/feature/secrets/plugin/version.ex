# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (elixir/lib/voxgig_plugin/version.ex)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
defmodule Voxgig.Plugin.Version do
  @moduledoc """
  Versions and ranges (section 11.2).

  TWO FIELDS AND ONE PREDICATE. A capability declares `version`, a concrete
  version. A requirement declares `range`. A requirement is satisfied when
  the names match, the `match` passes, and the provider's `version` falls
  inside the requirement's `range`.

  That is the whole rule. There is no third field and no second comparison
  - an earlier draft added a provider-side `compat` range, which left three
  values and no statement of how they combine, and three defensible
  readings of one declaration is worse than the ambiguity it was introduced
  to fix.
  """

  alias Voxgig.Plugin.Types

  @doc """
  A COMPONENT IS BOUNDED, and the bound is the model's, not the host
  language's. Elixir's integers are unbounded and JavaScript's numbers stop
  being exact past 2**53, so a twenty-digit component parsed to an exact
  value here and a rounded one there. 2**31-1 is the smallest bound every
  target language holds exactly, which makes it the model's.
  """
  def component_max, do: 2_147_483_647

  defp component(digits, whole, field) do
    value = String.to_integer(digits)

    if component_max() < value do
      Types.fail("plugin_bad_range",
                 "version component out of range in #{whole}: #{digits}",
                 %{field => whole})
    end

    value
  end

  # `1`, `1.2` or `1.2.3`, fully anchored.
  defp parts(text, whole, field) do
    pieces = String.split(text, ".")

    cond do
      3 < length(pieces) ->
        nil

      Enum.any?(pieces, fn p -> "" == p or not String.match?(p, ~r/\A[0-9]+\z/) end) ->
        nil

      true ->
        parsed = Enum.map(pieces, &component(&1, whole, field))
        parsed ++ List.duplicate(0, 3 - length(parsed))
    end
  end

  @doc """
  Two forms and no more (section 11.2): `'2.1'` is >= 2.1.0 and < 3.0.0;
  `'~2.1'` is >= 2.1.0 and < 2.2.0.
  """
  def parse_range(range) when is_binary(range) and range != "" do
    tilde = String.starts_with?(range, "~")
    body = if tilde, do: String.slice(range, 1..-1//1), else: range

    case parts(body, range, "range") do
      nil ->
        Types.fail("plugin_bad_range", "invalid range: #{range}", %{"range" => range})

      [major, minor, patch] ->
        hi = if tilde, do: [major, minor + 1, 0], else: [major + 1, 0, 0]
        %{"lo" => [major, minor, patch], "hi" => hi}
    end
  end

  def parse_range(range) do
    Types.fail("plugin_bad_range", "invalid range: #{Types.encode(range)}", %{"range" => range})
  end

  def parse_version(version) when is_binary(version) do
    case parts(version, version, "version") do
      nil ->
        Types.fail("plugin_bad_range", "invalid version: #{version}", %{"version" => version})

      triple ->
        triple
    end
  end

  def parse_version(version) do
    Types.fail("plugin_bad_range", "invalid version: #{Types.encode(version)}",
               %{"version" => version})
  end

  @doc "The one satisfaction predicate: lo <= version < hi."
  def satisfies(version, range) do
    v = parse_version(version)
    r = parse_range(range)
    compare(v, r["lo"]) >= 0 and compare(v, r["hi"]) < 0
  end

  @doc """
  satisfies for the internal callers that treat an unparseable version or
  range as "does not satisfy" - Capability and Graph, both of which run
  over data the corpus has already admitted.
  """
  def satisfiesq(version, range) do
    satisfies(version, range)
  rescue
    Voxgig.Plugin.Error -> false
  end

  defp compare([], []), do: 0
  defp compare([a | as], [b | bs]) do
    cond do
      a < b -> -1
      a > b -> 1
      true -> compare(as, bs)
    end
  end

  @doc "The version triple as a comparable key, for the capability rank."
  def version_parts(text) do
    text
    |> to_string()
    |> String.split(".")
    |> Enum.map(fn p ->
      case Integer.parse(p) do
        {n, _} -> n
        :error -> 0
      end
    end)
  end
end
