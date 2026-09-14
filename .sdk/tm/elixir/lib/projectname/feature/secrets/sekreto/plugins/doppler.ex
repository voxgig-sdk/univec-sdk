# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (elixir/plugins/doppler.ex)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# Doppler, as a sekreto plugin.
#
# A port of typescript/plugins/doppler.ts, which is canonical.

defmodule Sekreto.Plugins.Doppler do
  @moduledoc """
  The `doppler` provider kind.

  A plugin module: nothing under `src/` names it, and a chain that does not
  name this kind never loads it. See docs/design/plugin-providers.md.
  """

  alias Sekreto.Cell
  alias Sekreto.Error
  alias Sekreto.Json
  alias Sekreto.Plugins.Http
  alias Sekreto.Plugins.Httpjson
  alias Sekreto.ProviderSpec
  alias Sekreto.Providers

  @doc """
  The `doppler` provider kind, as a voxgig/plugin definition.

  The calling project passes it to the constructor, and only then can a
  chain name the kind:

      Sekreto.new(chain, plugins: [Sekreto.Plugins.Doppler.doppler()])
  """
  def doppler, do: Providers.providerplugin("doppler", &fromspec/1)

  @doc """
  Doppler.

  The whole config is downloaded once - Doppler's own bulk endpoint - and
  answered from memory, like a remote .env: `api.token` is the `API_TOKEN`
  entry. A service token is config-scoped, so project and config are only
  needed with broader tokens.

  The `prefix` option is not consulted by this kind.
  """
  def doppler(token, project, config, addr) do
    cell = Cell.new(:unloaded)

    load = fn ->
      useaddr = Httpjson.trimslash(Providers.first([addr, "https://api.doppler.com"]))
      Providers.checkaddr(useaddr)

      url =
        useaddr <>
          "/v3/configs/config/secrets/download?format=json" <>
          if("" == project, do: "", else: "&project=" <> Http.uriescape(project)) <>
          if("" == config, do: "", else: "&config=" <> Http.uriescape(config))

      res = Httpjson.fetchjson("GET", url, [{"authorization", "Bearer " <> token}])
      body = Json.asobj(res.body)

      if 200 != res.status or :none == body do
        raise Error, message: "sekreto: doppler error: " <> Httpjson.tostr(res.status)
      end

      Enum.reduce(body, [], fn {key, value}, out ->
        case Json.text(value) do
          :none -> out
          text -> Sekreto.pairput(out, key, text)
        end
      end)
    end

    %{
      lookup: fn name ->
        values =
          case Cell.get(cell) do
            :unloaded ->
              # A failed load caches nothing, so the next lookup retries.
              loaded = load.()
              Cell.put(cell, loaded)
              loaded

            loaded ->
              loaded
          end

        Sekreto.pairget(values, Sekreto.envkey(name))
      end,
      describe: fn ->
        if "" == project, do: "doppler", else: "doppler:" <> project <> "/" <> config
      end
    }
  end

  defp fromspec(%ProviderSpec{} = spec),
    do: doppler(spec.token, spec.project, spec.config, spec.addr)
end
