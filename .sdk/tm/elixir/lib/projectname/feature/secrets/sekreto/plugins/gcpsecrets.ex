# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (elixir/plugins/gcpsecrets.ex)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# GCP Secret Manager, as a sekreto plugin.
#
# A port of typescript/plugins/gcpsecrets.ts, which is canonical.

defmodule Sekreto.Plugins.Gcpsecrets do
  @moduledoc """
  The `gcpsecrets` provider kind.

  A plugin module: nothing under `src/` names it, and a chain that does not
  name this kind never loads it. See docs/design/plugin-providers.md.
  """

  alias Sekreto.Cell
  alias Sekreto.Error
  alias Sekreto.Json
  alias Sekreto.Plugins.Httpjson
  alias Sekreto.ProviderSpec
  alias Sekreto.Providers

  @doc """
  The `gcpsecrets` provider kind, as a voxgig/plugin definition.

  The calling project passes it to the constructor, and only then can a
  chain name the kind:

      Sekreto.new(chain, plugins: [Sekreto.Plugins.Gcpsecrets.gcpsecrets()])
  """
  def gcpsecrets, do: Providers.providerplugin("gcpsecrets", &fromspec/1)

  @doc """
  GCP Secret Manager.

  `api.token` reads secret `api_token` (dots flattened to `_`; Secret
  Manager ids have no hierarchy and reject dots), latest version. The token
  comes from config, then `GOOGLE_OAUTH_ACCESS_TOKEN`, then the GCE/GKE
  metadata server - so on Google's own platform no credential configuration
  is needed at all.

  The metadata call itself is plain http to a link-local host by platform
  design; no credential rides on it, so `checkaddr` guards the Secret
  Manager address instead.
  """
  def gcpsecrets(project, token, addr, metadataaddr) do
    cell = Cell.new(%{token: "", renewat: Httpjson.never()})

    usemetadataaddr = fn ->
      cond do
        "" != metadataaddr -> metadataaddr
        "" != Providers.getenv("GCE_METADATA_HOST") ->
          "http://" <> Providers.getenv("GCE_METADATA_HOST")
        true -> "http://metadata.google.internal"
      end
    end

    login = fn ->
      configured = Providers.first([token, Providers.getenv("GOOGLE_OAUTH_ACCESS_TOKEN")])

      if "" != configured do
        Cell.put(cell, %{token: configured, renewat: Httpjson.never()})
      else
        url =
          Httpjson.trimslash(usemetadataaddr.()) <>
            "/computeMetadata/v1/instance/service-accounts/default/token"

        res = Httpjson.fetchjson("GET", url, [{"Metadata-Flavor", "Google"}])
        got = Json.text(Json.dig(res.body, ["access_token"]))

        if 200 != res.status or :none == got or "" == got do
          raise Error, message: "sekreto: gcp: no token and metadata server did not answer"
        end

        renewat = Httpjson.renewtime(Json.dig(res.body, ["expires_in"]))
        Cell.put(cell, %{token: got, renewat: renewat})
      end
    end

    %{
      lookup: fn name ->
        if "" == project, do: raise(Error, message: "sekreto: gcp: no project")

        useaddr = Providers.first([addr, "https://secretmanager.googleapis.com"])
        Providers.checkaddr(useaddr)

        if Httpjson.expired?(cell), do: login.()

        url =
          Httpjson.trimslash(useaddr) <>
            "/v1/projects/" <>
            project <> "/secrets/" <> Sekreto.flatname(name, "_") <> "/versions/latest:access"

        res =
          Httpjson.fetchjson("GET", url, [{"authorization", "Bearer " <> Cell.get(cell).token}])

        cond do
          404 == res.status ->
            nil

          200 != res.status ->
            raise Error,
              message: "sekreto: gcp error: " <> Httpjson.tostr(res.status) <> ": " <> url

          true ->
            case Json.asstr(Json.dig(res.body, ["payload", "data"])) do
              :none ->
                nil

              data ->
                case Httpjson.unbase64(data) do
                  :error -> raise Error, message: "sekreto: gcp: undecodable secret"
                  text -> text
                end
            end
        end
      end,
      describe: fn -> "gcpsecrets:" <> project end
    }
  end

  defp fromspec(%ProviderSpec{} = spec),
    do: gcpsecrets(spec.project, spec.token, spec.addr, spec.metadataaddr)
end
