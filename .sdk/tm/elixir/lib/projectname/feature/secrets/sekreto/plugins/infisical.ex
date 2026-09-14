# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (elixir/plugins/infisical.ex)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# Infisical, as a sekreto plugin.
#
# A port of typescript/plugins/infisical.ts, which is canonical.

defmodule Sekreto.Plugins.Infisical do
  @moduledoc """
  The `infisical` provider kind.

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
  The `infisical` provider kind, as a voxgig/plugin definition.

  The calling project passes it to the constructor, and only then can a
  chain name the kind:

      Sekreto.new(chain, plugins: [Sekreto.Plugins.Infisical.infisical()])
  """
  def infisical, do: Providers.providerplugin("infisical", &fromspec/1)

  @doc """
  Infisical.

  `api.token` reads the secret keyed `API_TOKEN` (Infisical's own
  convention is environment-style keys) at a secret path in one environment
  of a project. Auth is a token, or a universal-auth (machine identity)
  login with clientid/clientsecret.
  """
  def infisical(opts) do
    cell = Cell.new(%{token: "", renewat: Httpjson.never()})

    login = fn useaddr ->
      if "" != opts.token do
        Cell.put(cell, %{token: opts.token, renewat: Httpjson.never()})
      else
        if "" == opts.clientid or "" == opts.clientsecret do
          raise Error, message: "sekreto: infisical: no token and no client credentials"
        end

        body =
          Json.obj([
            {"clientId", Json.str(opts.clientid)},
            {"clientSecret", Json.str(opts.clientsecret)}
          ])

        res =
          Httpjson.fetchjson(
            "POST",
            useaddr <> "/api/v1/auth/universal-auth/login",
            [{"content-type", "application/json"}],
            Json.stringify(body)
          )

        got = Json.text(Json.dig(res.body, ["accessToken"]))

        if 200 != res.status or :none == got or "" == got do
          raise Error, message: "sekreto: infisical login failed: " <> Httpjson.tostr(res.status)
        end

        # camelCase, unlike everyone else's expires_in.
        renewat = Httpjson.renewtime(Json.dig(res.body, ["expiresIn"]))
        Cell.put(cell, %{token: got, renewat: renewat})
      end
    end

    %{
      lookup: fn name ->
        useaddr = Httpjson.trimslash(Providers.first([opts.addr, "https://app.infisical.com"]))
        Providers.checkaddr(useaddr)

        if "" == opts.project or "" == opts.environment do
          raise Error, message: "sekreto: infisical: no project/environment"
        end

        if Httpjson.expired?(cell), do: login.(useaddr)

        url =
          useaddr <>
            "/api/v3/secrets/raw/" <>
            Sekreto.envkey(name) <>
            "?workspaceId=" <>
            Http.uriescape(opts.project) <>
            "&environment=" <>
            Http.uriescape(opts.environment) <>
            "&secretPath=" <> Http.uriescape(Providers.first([opts.path, "/"]))

        res =
          Httpjson.fetchjson("GET", url, [{"authorization", "Bearer " <> Cell.get(cell).token}])

        cond do
          404 == res.status -> nil
          200 != res.status ->
            raise Error, message: "sekreto: infisical error: " <> Httpjson.tostr(res.status)
          true -> Httpjson.nonone(Json.text(Json.dig(res.body, ["secret", "secretValue"])))
        end
      end,
      describe: fn -> "infisical:" <> opts.project <> "/" <> opts.environment end
    }
  end

  defp fromspec(%ProviderSpec{} = spec) do
    infisical(%{
      addr: spec.addr,
      token: spec.token,
      clientid: spec.clientid,
      clientsecret: spec.clientsecret,
      project: spec.project,
      environment: spec.environment,
      path: spec.path
    })
  end
end
