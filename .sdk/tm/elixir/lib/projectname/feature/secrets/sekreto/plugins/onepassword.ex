# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (elixir/plugins/onepassword.ex)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# 1Password, through a Connect server, as a sekreto plugin.
#
# A port of typescript/plugins/onepassword.ts, which is canonical.

defmodule Sekreto.Plugins.Onepassword do
  @moduledoc """
  The `onepassword` provider kind.

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
  The `onepassword` provider kind, as a voxgig/plugin definition.

  The calling project passes it to the constructor, and only then can a
  chain name the kind:

      Sekreto.new(chain, plugins: [Sekreto.Plugins.Onepassword.onepassword()])
  """
  def onepassword, do: Providers.providerplugin("onepassword", &fromspec/1)

  @doc """
  1Password, through a Connect server.

  The item titled `api.token` (titles keep their dots), in the named vault.
  The value is the field with purpose PASSWORD, or the field labelled
  `value`. A vault that cannot be found is an error - config names it, so
  its absence is a broken store, not a missing secret.
  """
  def onepassword(addr, token, vault) do
    cell = Cell.new(:unresolved)
    auth = [{"authorization", "Bearer " <> token}]

    resolvevault = fn useaddr ->
      if "" == vault, do: raise(Error, message: "sekreto: onepassword: no vault")

      res = Httpjson.fetchjson("GET", useaddr <> "/v1/vaults", auth)
      list = Json.asarr(res.body)

      if 200 != res.status or :none == list do
        raise Error,
          message:
            "sekreto: onepassword error: " <> Httpjson.tostr(res.status) <> ": listing vaults"
      end

      found =
        Enum.find(list, fn entry ->
          vault == Json.text(Json.dig(entry, ["id"])) or
            vault == Json.text(Json.dig(entry, ["name"]))
        end)

      if nil == found do
        raise Error, message: "sekreto: onepassword: no vault named " <> vault
      end

      case Json.text(Json.dig(found, ["id"])) do
        :none -> ""
        id -> id
      end
    end

    %{
      lookup: fn name ->
        Sekreto.checkname(name)

        useaddr = Httpjson.trimslash(addr)
        if "" == useaddr, do: raise(Error, message: "sekreto: onepassword: no addr")
        Providers.checkaddr(useaddr)

        id =
          case Cell.get(cell) do
            :unresolved ->
              resolved = resolvevault.(useaddr)
              Cell.put(cell, resolved)
              resolved

            resolved ->
              resolved
          end

        filter = Http.uriescape(~s|title eq "| <> name <> ~s|"|)
        found =
          Httpjson.fetchjson(
            "GET",
            useaddr <> "/v1/vaults/" <> id <> "/items?filter=" <> filter,
            auth
          )

        items = Json.asarr(found.body)

        if 200 != found.status or :none == items do
          raise Error,
            message:
              "sekreto: onepassword error: " <>
                Httpjson.tostr(found.status) <> ": finding " <> name
        end

        if [] == items do
          nil
        else
          itemid =
            case Json.text(Json.dig(hd(items), ["id"])) do
              :none -> ""
              value -> value
            end

          item =
            Httpjson.fetchjson("GET", useaddr <> "/v1/vaults/" <> id <> "/items/" <> itemid, auth)

          if 200 != item.status do
            raise Error,
              message:
                "sekreto: onepassword error: " <>
                  Httpjson.tostr(item.status) <> ": reading " <> name
          end

          fields =
            case Json.asarr(Json.dig(item.body, ["fields"])) do
              :none -> []
              value -> value
            end

          # Two full passes, in order: purpose first, then label.
          chosen =
            Enum.find(fields, fn field ->
              "PASSWORD" == Json.asstr(Json.dig(field, ["purpose"]))
            end) ||
              Enum.find(fields, fn field ->
                "value" == Json.asstr(Json.dig(field, ["label"]))
              end)

          if nil == chosen, do: nil, else: Httpjson.nonone(Json.text(Json.dig(chosen, ["value"])))
        end
      end,
      describe: fn -> "onepassword:" <> vault end
    }
  end

  defp fromspec(%ProviderSpec{} = spec), do: onepassword(spec.addr, spec.token, spec.vault)
end
