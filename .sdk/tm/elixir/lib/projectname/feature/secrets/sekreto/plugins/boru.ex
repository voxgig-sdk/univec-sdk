# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (elixir/plugins/boru.ex)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# A boru vault, as a sekreto plugin.
#
# The only kind that reaches for BOTH edges: a child process for the CLI,
# and HTTPS for `boru vault serve`. Either one alone would keep it out of
# the core.
#
# A port of typescript/plugins/boru.ts, which is canonical.

defmodule Sekreto.Plugins.Boru do
  @moduledoc """
  The `boru` provider kind.

  A plugin module: nothing under `src/` names it, and a chain that does not
  name this kind never loads it. See docs/design/plugin-providers.md.
  """

  alias Sekreto.Error
  alias Sekreto.Json
  alias Sekreto.Plugins.Httpjson
  alias Sekreto.Plugins.Proc
  alias Sekreto.ProviderSpec
  alias Sekreto.Providers

  @doc """
  The `boru` provider kind, as a voxgig/plugin definition.

  The calling project passes it to the constructor, and only then can a
  chain name the kind:

      Sekreto.new(chain, plugins: [Sekreto.Plugins.Boru.boru()])
  """
  def boru, do: Providers.providerplugin("boru", &fromspec/1)

  @doc """
  A boru vault.

  Two ways in, both boru's own.

  With no `addr`, the CLI: `boru vault get --reveal <alias>` prints the
  secret on stdout and nothing else. The passphrase is read by boru itself
  from `BORU_VAULT_PASSPHRASE`; sekreto never accepts it as config and
  never puts it on a command line, where it would show up in the process
  table.

  With an `addr`, boru's wire protocol: a read-only, HashiCorp-shaped
  provision API authenticated by a capability token. A sekreto name is
  already a valid boru alias, and boru aliases keep their dots, so
  `api.token` is the single path segment `api.token` - not the `api`/`token`
  split a HashiCorp KV gets. The value is the `value` field.
  """
  def boru(commandgiven, namespace, home, addrgiven, token, mountgiven) do
    command = Providers.first([commandgiven, "boru"])
    addr = Httpjson.trimslash(addrgiven)
    mount = Providers.first([mountgiven, "secret"])

    %{
      lookup: fn name ->
        Sekreto.checkname(name)

        if "" != addr do
          Providers.checkaddr(addr)

          # The dotted name stays one path segment: boru aliases keep dots.
          alias_ = if "" == namespace, do: name, else: namespace <> "/" <> name
          url = addr <> "/v1/" <> mount <> "/data/" <> alias_

          res = Httpjson.fetchjson("GET", url, [{"X-Vault-Token", token}])

          cond do
            404 == res.status ->
              nil

            200 != res.status ->
              raise Error,
                message: "sekreto: boru serve error: " <> Httpjson.tostr(res.status) <> ": " <> url

            true ->
              Httpjson.nonone(Json.text(Json.dig(res.body, ["data", "data", "value"])))
          end
        else
          alias_ = if "" == namespace, do: name, else: namespace <> ":" <> name
          env = if "" == home, do: [], else: [{"BORU_HOME", home}]

          ran = Proc.runcmd(command, ["vault", "get", "--reveal", alias_], env)

          cond do
            # boru prints the value and one newline, and nothing else.
            0 == ran.status ->
              Sekreto.dropsuffix(ran.out, "\n")

            # "no alias named" is boru saying it does not hold this secret,
            # which is a miss. A locked vault or a wrong passphrase is not:
            # treating it as one would fall through to a weaker store
            # without saying so.
            borumiss(ran.why) ->
              nil

            true ->
              raise Error,
                message:
                  "sekreto: boru vault error: " <>
                    if("" == ran.why, do: "exit " <> Httpjson.tostr(ran.status), else: ran.why)
          end
        end
      end,
      describe: fn ->
        cond do
          "" != addr -> "boru:" <> addr
          "" != namespace -> "boru:" <> namespace
          true -> "boru"
        end
      end
    }
  end

  @doc """
  Does this boru failure mean "no such secret" rather than "I could not
  answer"? Matched on boru's own wording for a missing alias.
  """
  def borumiss(why), do: String.contains?(why, "no alias named")

  defp fromspec(%ProviderSpec{} = spec),
    do: boru(spec.command, spec.namespace, spec.home, spec.addr, spec.token, spec.mount)
end
