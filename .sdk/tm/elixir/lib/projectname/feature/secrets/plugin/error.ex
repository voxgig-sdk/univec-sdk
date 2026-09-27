# VENDORED: @voxgig/plugin sdk-20260925-1316-0 (elixir/lib/voxgig_plugin/error.ex)
# Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
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
