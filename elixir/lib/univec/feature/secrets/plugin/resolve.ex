# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (elixir/lib/voxgig_plugin/resolve.ex)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
defmodule Voxgig.Plugin.Resolve do
  @moduledoc """
  Dynamic resolution (section 10.2) - name to candidate module ids.

  PURE. It returns the ids a host WOULD try, in order; it does not load
  anything. That separation is what lets the corpus pin resolution in every
  language including those with no dynamic loading at all, and it is why
  section 15.4 puts real module loading in per-port integration tests
  rather than here.
  """

  alias Voxgig.Plugin.Types

  def default_sources do
    [%{"kind" => "module",
       "prefix" => ["@voxgig/plugin-", "voxgig-plugin-", "plugin-", ""]}]
  end

  def resolve_candidates(name, sources) do
    # A SCOPED NAME RESOLVES VERBATIM ONLY (section 10.2). `@acme/thing` is
    # already a package id; prefixing it produces
    # `@voxgig/plugin-@acme/thing`, which is not a thing that can exist.
    if String.starts_with?(name, "@") do
      [name]
    else
      list = if is_list(sources) and [] != sources, do: sources, else: default_sources()

      list
      |> Enum.flat_map(fn src ->
        case Types.get(src, "kind") do
          "module" ->
            prefixes = Types.get(src, "prefix")
            prefixes = if is_list(prefixes) and [] != prefixes, do: prefixes, else: [""]
            Enum.map(prefixes, &(&1 <> name))

          "path" ->
            dir = String.replace(Types.get(src, "dir") || "", ~r{/+\z}, "")
            [dir <> "/" <> name]

          _ ->
            []
        end
      end)
      |> Enum.uniq()
    end
  end

  @doc """
  A MODULE PATH IS NOT A NAME (section 10.2). The ref grammar starts a name
  with a letter or `@`, so `./local/thing` is not a ref and never reaches
  candidate generation - seneca allows a path where a plugin name goes, and
  this design deliberately does not, because a ref is an ADDRESS WITHIN A
  HOST and a path is a LOCATION ON A DISK.
  """
  def resolve_from(from), do: [from]
end
