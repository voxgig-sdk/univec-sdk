# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (elixir/plugins/secretspec.ex)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# SecretSpec, as a sekreto plugin.
#
# A child process and nothing else: this is the one plugin kind that opens
# no socket, so it reaches `Sekreto.Plugins.Proc` and never the HTTP
# helper. Loading it loads no TLS stack. An exit status is an integer, so
# the message below formats it with `Integer.to_string/1` rather than with
# `Httpjson.tostr/1` - reaching a shared HTTP module for a one-line string
# function is exactly how a socketless kind ends up carrying a client.
#
# A port of typescript/plugins/secretspec.ts, which is canonical.

defmodule Sekreto.Plugins.Secretspec do
  @moduledoc """
  The `secretspec` provider kind.

  A plugin module: nothing under `src/` names it, and a chain that does not
  name this kind never loads it. See docs/design/plugin-providers.md.
  """

  alias Sekreto.Error
  alias Sekreto.Plugins.Proc
  alias Sekreto.ProviderSpec
  alias Sekreto.Providers

  @doc """
  The `secretspec` provider kind, as a voxgig/plugin definition.

  The calling project passes it to the constructor, and only then can a
  chain name the kind:

      Sekreto.new(chain, plugins: [Sekreto.Plugins.Secretspec.secretspec()])
  """
  def secretspec, do: Providers.providerplugin("secretspec", &fromspec/1)

  @doc """
  SecretSpec.

  SecretSpec is a declaration - a `secretspec.toml` naming the secrets a
  project needs - plus a chain of its own backends to satisfy them from.
  That makes it the same shape as sekreto one level down, and the reason to
  support it is the same reason sekreto exists: a project that has already
  declared its secrets there should not have to declare them again here.

  A reason is required, not optional: SecretSpec records every read in an
  audit log and refuses to read at all without one.
  """
  def secretspec(commandgiven, file, profile, backend, reason, prefix) do
    command = Providers.first([commandgiven, "secretspec"])

    %{
      lookup: fn name ->
        key = Sekreto.envkey(name, prefix)

        args =
          (if "" == file, do: [], else: ["--file", file]) ++
            ["get", key] ++
            (if "" == backend, do: [], else: ["--provider", backend]) ++
            (if "" == profile, do: [], else: ["--profile", profile]) ++
            ["--reason", Providers.first([reason, "sekreto"])]

        ran = Proc.runcmd(command, args)

        cond do
          0 == ran.status ->
            Sekreto.dropsuffix(ran.out, "\n")

          secretspecmiss(ran.why, key) ->
            nil

          true ->
            raise Error,
              message:
                "sekreto: secretspec error: " <>
                  if("" == ran.why, do: "exit " <> Integer.to_string(ran.status), else: ran.why)
        end
      end,
      describe: fn -> if "" == backend, do: "secretspec", else: "secretspec:" <> backend end
    }
  end

  @doc """
  Does this SecretSpec failure mean "no such secret" rather than "I could
  not answer"?

  SecretSpec says `Secret 'API_TOKEN' not found` for both a name it does
  not declare and one declared with no value, and both are misses.

  MATCHED ON THE WHOLE PHRASE, NOT ON "not found". SecretSpec also says
  `Provider backend 'keyring' not found`, which is a store that could not
  answer at all - and reading that as a miss is the worst failure this
  library has, because the chain then falls through to a weaker store
  without saying so.
  """
  def secretspecmiss(why, key), do: String.contains?(why, "Secret '" <> key <> "' not found")

  defp fromspec(%ProviderSpec{} = spec),
    do: secretspec(spec.command, spec.file, spec.profile, spec.backend, spec.reason, spec.prefix)
end
