# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (elixir/lib/voxgig_plugin/catalog.ex)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
defmodule Voxgig.Plugin.Catalog do
  @moduledoc """
  The definition catalog (section 10.1).

  A definition is registered once and may back many instances. Option
  shapes are validated AT REGISTRATION, not when a document happens to
  exercise a key - so a malformed shape fails once, and in the same place
  everywhere (section 9.4).

  THE CATALOG IS A VALUE HERE, not an object with an `add` method. Every
  other port hands out a mutable catalog and lets the host and its caller
  share it; in Elixir a value cannot be mutated, so `add/2` RETURNS the
  new catalog and the host - which is a process, and the only mutable
  thing in the port - owns the one the host reads. `Host.catalog_add/2`
  is how a caller extends a live host's catalog, and it is the only path
  that has to exist: a caller holding a catalog value can simply keep the
  result of `add/2`.
  """

  alias Voxgig.Plugin.Config
  alias Voxgig.Plugin.Ref
  alias Voxgig.Plugin.Types

  defstruct defs: %{}

  def add(%__MODULE__{} = catalog, definition) do
    name = Types.get(definition, "name")

    if not (is_map(definition) and Ref.check_name(name)) do
      shown = if is_map(definition), do: name, else: definition
      Types.fail("plugin_definition_name", "invalid definition name: #{Types.encode(shown)}")
    end

    # Validate the shape HERE. Deferring it to resolution time means a
    # malformed shape surfaces at a different moment in every host that
    # loads it, which is the divergence the stated domain exists to
    # prevent.
    shape = Types.get(definition, "shape")
    if shape, do: Config.check_shape(shape)

    %__MODULE__{catalog | defs: Map.put(catalog.defs, name, definition)}
  end

  def get(%__MODULE__{defs: defs}, name), do: Map.get(defs, name)

  def has?(%__MODULE__{defs: defs}, name), do: Map.has_key?(defs, name)

  def names(%__MODULE__{defs: defs}), do: defs |> Map.keys() |> Enum.sort()

  def make_catalog(definitions \\ nil) do
    Enum.reduce(definitions || [], %__MODULE__{}, &add(&2, &1))
  end
end
