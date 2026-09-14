# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (elixir/src/provider.ex)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# A source of secrets.
#
# A provider answers one question: "do you have this secret?" It returns
# the value, or `nil` to mean "ask the next one". Nothing else about a
# provider is visible to the caller - which is the point: an app reads
# `api.token` and never learns whether it came from the environment, a
# .env file, HashiCorp Vault or a boru vault.
#
# A provider is a plain map of two functions rather than a behaviour, so
# that anything answering `lookup` is a provider: a caller can pass a
# three-line map of its own and never name a module here.

defmodule Sekreto.Provider do
  @moduledoc """
  The provider shape: `%{lookup: (name -> value | nil), describe: (-> text)}`.

  `lookup` answers the value, or `nil` when this provider does not have it.
  The empty string is a value. A provider that could not answer at all
  raises `Sekreto.Error`; it never answers `nil` for that.
  """

  @typedoc "Anything with a one-argument `lookup` and a no-argument `describe`."
  @type t :: %{required(:lookup) => (binary -> binary | nil), required(:describe) => (-> binary)}

  @doc """
  Is this a live provider rather than a spec?

  Duck-typed on `lookup` being callable, not on any struct or module
  identity, so a caller's own map counts.
  """
  def provider?(value), do: is_map(value) and is_function(Map.get(value, :lookup), 1)

  @doc "The value, or nil if this provider does not have it."
  def lookup(provider, name), do: provider.lookup.(name)

  @doc "A short description, shown by `Sekreto.sources/1`."
  def describe(provider), do: provider.describe.()
end

defmodule Sekreto.Cell do
  @moduledoc """
  One mutable slot, for the state a provider keeps between lookups: a
  memoised `.env` file, a logged-in token and its renewal time, a resolved
  1Password vault id.

  Nothing on the BEAM is mutable, so that state lives in a process. An
  Agent is the smallest thing in the standard library that is one; it is
  linked to whoever built the provider, so it goes away when they do.

  Never hold I/O inside the Agent: a lookup that takes the full ten-second
  transport bound would outlive the Agent's own call timeout. Read, work,
  then write - the same single-threaded discipline the `var` fields of the
  JVM ports have.
  """

  def new(value) do
    {:ok, pid} = Agent.start_link(fn -> value end)
    pid
  end

  def get(cell), do: Agent.get(cell, & &1)

  def put(cell, value), do: Agent.update(cell, fn _old -> value end)
end
