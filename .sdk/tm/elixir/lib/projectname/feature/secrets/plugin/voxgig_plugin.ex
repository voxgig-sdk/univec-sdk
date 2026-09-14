# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (elixir/lib/voxgig_plugin.ex)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
defmodule Voxgig.Plugin do
  @moduledoc """
  The canonical surface `make parity` checks (AGENTS.md section 4). Small
  on purpose (section 19): everything else is functions on `Host` and
  `Inst`, because a library that grows a second public entry point per
  feature is a library twenty ports pay for twice.

  ELEVEN NAMES, AND THEY ARE DELEGATIONS RATHER THAN DEFINITIONS. The
  implementation lives in the module named for its design section, so a
  reader who arrives at `resolve_order/2` from the corpus lands in
  `Voxgig.Plugin.Order` where section 7 is quoted, not in a facade that
  forwards.
  """

  alias Voxgig.Plugin.Catalog
  alias Voxgig.Plugin.Config
  alias Voxgig.Plugin.Env
  alias Voxgig.Plugin.Host
  alias Voxgig.Plugin.Order
  alias Voxgig.Plugin.Ref
  alias Voxgig.Plugin.Resolve

  # host construction
  defdelegate make_host(options \\ nil), to: Host
  defdelegate make_catalog(definitions \\ nil), to: Catalog

  # refs - the first thing a new port implements (section 4)
  defdelegate parse_ref(str), to: Ref
  defdelegate format_ref(name, tag), to: Ref
  defdelegate check_name(name), to: Ref
  defdelegate check_tag(tag), to: Ref

  # pure functions over documents and definitions
  defdelegate normalize_config(input), to: Config
  defdelegate resolve_options(input), to: Config
  defdelegate resolve_order(bindings, pin \\ nil), to: Order
  defdelegate resolve_candidates(name, sources), to: Resolve
  defdelegate apply_env(input), to: Env
end
