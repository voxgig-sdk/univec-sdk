# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (elixir/lib/voxgig_plugin/error.ex)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
defmodule Voxgig.Plugin.Error do
  @moduledoc """
  Every error carries a section 12 code. Ports compare by CODE and never by
  message: wording is a port's own business, and pinning the words would
  make every translation a corpus change. The FORMAT, however, is pinned -
  a parseable message is what makes a log searchable across twenty
  languages.
  """
  defexception [:code, :text, :details, :message]
end
