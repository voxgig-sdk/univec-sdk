# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (elixir/plugins/hashicorp.ex)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# HashiCorp Vault, as a sekreto plugin.
#
# HTTPS to a vault, plus a local file for the Kubernetes
# service-account JWT. The socket is why this kind is not built in.
#
# A port of typescript/plugins/hashicorp.ts, which is canonical.

defmodule Sekreto.Plugins.Hashicorp do
  @moduledoc """
  The `hashicorp` provider kind.

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
  The `hashicorp` provider kind, as a voxgig/plugin definition.

  The calling project passes it to the constructor, and only then can a
  chain name the kind:

      Sekreto.new(chain, plugins: [Sekreto.Plugins.Hashicorp.hashicorp()])
  """
  def hashicorp, do: Providers.providerplugin("hashicorp", &fromspec/1)

  @doc """
  HashiCorp Vault.

  KV v2 (the default): `api.token` reads `{addr}/v1/{mount}/data/api` and
  takes the `token` field of `data.data`. KV v1 reads
  `{addr}/v1/{mount}/api` and takes the field of `data`. A 404 means "not
  here" - a miss - so a vault can sit in a chain with fallbacks.

  A Vault Enterprise namespace rides the `X-Vault-Namespace` header, on
  logins as well as reads.

  Instead of being handed a token, the provider can log in: Kubernetes auth
  (the pod's service-account JWT, from its conventional path) or AppRole. A
  failed login is an error, never a miss - it means this store could not
  answer at all.
  """
  def hashicorp(addr, token, mountgiven, kvgiven, vaultnamespace, auth) do
    mount = Providers.first([mountgiven, "secret"])
    kv = kvgiven || 2

    # A version typo like kv: 3 must not quietly behave as v2 and turn its
    # 404s into misses; there is nothing safe to assume it meant.
    if 1 != kv and 2 != kv do
      raise Error, message: "sekreto: hashicorp: unsupported kv version: " <> Httpjson.tostr(kv)
    end

    # A configured token is kept forever; a logged-in token is renewed
    # shortly before its lease runs out - a long-running process must not
    # keep presenting a token the vault already expired.
    cell = Cell.new(%{token: token, renewat: Httpjson.never()})

    base = fn -> if "" == vaultnamespace, do: [], else: [{"X-Vault-Namespace", vaultnamespace}] end

    login = fn ->
      if nil == auth do
        raise Error, message: "sekreto: hashicorp: no token and no auth method"
      end

      authmount = Providers.first([auth.mount, auth.method])
      url = Httpjson.trimslash(addr) <> "/v1/auth/" <> authmount <> "/login"

      body =
        case auth.method do
          "kubernetes" ->
            jwt =
              if "" != auth.jwt do
                auth.jwt
              else
                jwtfile =
                  Providers.first([
                    auth.jwtfile,
                    "/var/run/secrets/kubernetes.io/serviceaccount/token"
                  ])

                case File.read(jwtfile) do
                  {:ok, text} ->
                    String.trim(text)

                  {:error, _why} ->
                    raise Error,
                      message: "sekreto: hashicorp: cannot read jwt file " <> jwtfile
                end
              end

            Json.obj([{"role", Json.str(auth.role)}, {"jwt", Json.str(jwt)}])

          "approle" ->
            Json.obj([
              {"role_id", Json.str(auth.roleid)},
              {"secret_id", Json.str(auth.secretid)}
            ])

          other ->
            raise Error, message: "sekreto: hashicorp: unknown auth method: " <> other
        end

      res = Httpjson.fetchjson("POST", url, base.(), Json.stringify(body))
      got = Json.text(Json.dig(res.body, ["auth", "client_token"]))

      if 200 != res.status or :none == got or "" == got do
        raise Error,
          message: "sekreto: hashicorp login failed: " <> Httpjson.tostr(res.status) <> ": " <> url
      end

      Cell.put(cell, %{
        token: got,
        renewat: Httpjson.renewtime(Json.dig(res.body, ["auth", "lease_duration"]))
      })
    end

    %{
      lookup: fn name ->
        Providers.checkaddr(addr)

        if Httpjson.expired?(cell), do: login.()

        ref = Sekreto.vaultref(name)
        stem = Httpjson.trimslash(addr) <> "/v1/" <> mount
        url = if 1 == kv, do: stem <> "/" <> ref.path, else: stem <> "/data/" <> ref.path

        headers = base.() ++ [{"X-Vault-Token", Cell.get(cell).token}]
        res = Httpjson.fetchjson("GET", url, headers)

        cond do
          404 == res.status ->
            nil

          200 != res.status ->
            raise Error,
              message: "sekreto: hashicorp error: " <> Httpjson.tostr(res.status) <> ": " <> url

          true ->
            data =
              if 1 == kv,
                do: Json.dig(res.body, ["data"]),
                else: Json.dig(res.body, ["data", "data"])

            Httpjson.nonone(Json.text(Json.dig(data, [ref.field])))
        end
      end,
      describe: fn -> "hashicorp:" <> addr <> "/" <> mount end
    }
  end

  defp fromspec(%ProviderSpec{} = spec),
    do: hashicorp(spec.addr, spec.token, spec.mount, spec.kv, spec.vaultnamespace, spec.auth)
end
