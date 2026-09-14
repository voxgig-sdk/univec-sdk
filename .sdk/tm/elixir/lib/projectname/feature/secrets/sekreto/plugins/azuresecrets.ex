# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (elixir/plugins/azuresecrets.ex)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# Azure Key Vault, as a sekreto plugin.
#
# A port of typescript/plugins/azuresecrets.ts, which is canonical.

defmodule Sekreto.Plugins.Azuresecrets do
  @moduledoc """
  The `azuresecrets` provider kind.

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

  # The Key Vault audience an Azure token is minted for.
  @resource "https://vault.azure.net"

  @doc """
  The `azuresecrets` provider kind, as a voxgig/plugin definition.

  The calling project passes it to the constructor, and only then can a
  chain name the kind:

      Sekreto.new(chain, plugins: [Sekreto.Plugins.Azuresecrets.azuresecrets()])
  """
  def azuresecrets, do: Providers.providerplugin("azuresecrets", &fromspec/1)

  @doc """
  Azure Key Vault.

  `api.token` reads secret `api-token` (dots flattened to `-`; Key Vault
  names allow nothing else), current version. The token comes from config,
  then a client-credentials login when tenant/clientid/clientsecret are
  given, then the IMDS managed-identity endpoint - so on Azure's own
  platform no credential configuration is needed.
  """
  def azuresecrets(opts) do
    cell = Cell.new(%{token: "", renewat: Httpjson.never()})

    login = fn ->
      cond do
        "" != opts.token ->
          Cell.put(cell, %{token: opts.token, renewat: Httpjson.never()})

        "" != opts.tenant and "" != opts.clientid and "" != opts.clientsecret ->
          useloginaddr = Providers.first([opts.loginaddr, "https://login.microsoftonline.com"])
          Providers.checkaddr(useloginaddr)

          url = Httpjson.trimslash(useloginaddr) <> "/" <> opts.tenant <> "/oauth2/v2.0/token"

          form =
            "grant_type=client_credentials&client_id=" <>
              Http.uriescape(opts.clientid) <>
              "&client_secret=" <>
              Http.uriescape(opts.clientsecret) <>
              "&scope=" <> Http.uriescape(@resource <> "/.default")

          res =
            Httpjson.fetchjson(
              "POST",
              url,
              [{"content-type", "application/x-www-form-urlencoded"}],
              form
            )

          got = Json.text(Json.dig(res.body, ["access_token"]))

          if 200 != res.status or :none == got or "" == got do
            raise Error, message: "sekreto: azure login failed: " <> Httpjson.tostr(res.status)
          end

          renewat = Httpjson.renewtime(Json.dig(res.body, ["expires_in"]))
          Cell.put(cell, %{token: got, renewat: renewat})

        true ->
          imds =
            Httpjson.trimslash(Providers.first([opts.imdsaddr, "http://169.254.169.254"])) <>
              "/metadata/identity/oauth2/token?api-version=2018-02-01&resource=" <>
              Http.uriescape(@resource)

          res = Httpjson.fetchjson("GET", imds, [{"Metadata", "true"}])
          got = Json.text(Json.dig(res.body, ["access_token"]))

          if 200 != res.status or :none == got or "" == got do
            raise Error,
              message: "sekreto: azure: no token, no client credentials, and IMDS did not answer"
          end

          # IMDS sends expires_in as a STRING, unlike everyone else.
          renewat = Httpjson.renewtime(Json.dig(res.body, ["expires_in"]))
          Cell.put(cell, %{token: got, renewat: renewat})
      end
    end

    %{
      lookup: fn name ->
        if "" == opts.vault, do: raise(Error, message: "sekreto: azure: no vault")

        # Only an explicit scheme is a URL; a vault NAMED httpvault must
        # still become https://httpvault.vault.azure.net.
        vaulturl =
          if String.starts_with?(opts.vault, "http://") or
               String.starts_with?(opts.vault, "https://") do
            opts.vault
          else
            "https://" <> opts.vault <> ".vault.azure.net"
          end

        Providers.checkaddr(vaulturl)

        if Httpjson.expired?(cell), do: login.()

        url =
          Httpjson.trimslash(vaulturl) <>
            "/secrets/" <>
            Sekreto.flatname(name, "-") <>
            "?api-version=" <> Providers.first([opts.apiversion, "7.4"])

        res =
          Httpjson.fetchjson("GET", url, [{"authorization", "Bearer " <> Cell.get(cell).token}])

        cond do
          404 == res.status ->
            nil

          200 != res.status ->
            raise Error,
              message:
                "sekreto: azure error: " <> Httpjson.tostr(res.status) <> ": " <> Http.bare(url)

          true ->
            Httpjson.nonone(Json.text(Json.dig(res.body, ["value"])))
        end
      end,
      describe: fn -> "azuresecrets:" <> opts.vault end
    }
  end

  defp fromspec(%ProviderSpec{} = spec) do
    azuresecrets(%{
      vault: spec.vault,
      token: spec.token,
      tenant: spec.tenant,
      clientid: spec.clientid,
      clientsecret: spec.clientsecret,
      loginaddr: spec.loginaddr,
      imdsaddr: spec.imdsaddr,
      apiversion: spec.apiversion
    })
  end
end
