# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (elixir/lib/voxgig_plugin/export.ex)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
defmodule Voxgig.Plugin.Export do
  @moduledoc """
  Exports (section 11).

  An instance publishes values for other plugins and for the application.

  THE UNQUALIFIED ALIAS IS THE INTERESTING PART. `retry/client` resolves to
  the UNTAGGED instance if one exists; if not, and exactly one tagged
  instance exports that key, it resolves to that one; if two do, it is
  `plugin_export_ambiguous` - deliberately diverging from seneca's silent
  last-wins, because with multi-instance as a headline feature an ambiguous
  alias is a defect waiting for production.
  """

  alias Voxgig.Plugin.Ref
  alias Voxgig.Plugin.Types

  @doc """
  `exported` is a list of `%{ref:, key:, value:}` - an internal shape,
  never a corpus value, so it uses atom keys where the data does not.
  """
  def resolve_export(spec, exported) do
    case :binary.match(spec, "/") do
      :nomatch ->
        Types.fail("plugin_export_ambiguous", "export spec needs a key: #{spec}",
                   %{"spec" => spec})

      {at, _} ->
        head = binary_part(spec, 0, at)
        key = binary_part(spec, at + 1, byte_size(spec) - at - 1)
        lookup(spec, head, key, exported)
    end
  end

  defp lookup(spec, head, key, exported) do
    want = Ref.canon(head)

    # A fully qualified ref: exactly one answer or none.
    qualified = Enum.find(exported, fn e -> e.ref == want and e.key == key end)

    if qualified do
      qualified.value
    else
      # An alias: the name, not a ref. Look at every instance of it.
      byname = Enum.filter(exported, fn e -> Ref.refname(e.ref) == head and e.key == key end)
      alias_of(spec, byname)
    end
  end

  defp alias_of(_spec, []), do: nil

  defp alias_of(spec, byname) do
    untagged = Enum.find(byname, fn e -> "" == Ref.parse_ref(e.ref)["tag"] end)

    cond do
      untagged ->
        untagged.value

      1 == length(byname) ->
        hd(byname).value

      true ->
        refs = byname |> Enum.map(& &1.ref) |> Enum.sort()

        Types.fail("plugin_export_ambiguous",
                   "alias #{spec} matches #{length(refs)} instances: #{Enum.join(refs, ", ")}",
                   %{"spec" => spec, "refs" => refs})
    end
  end
end
