# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (elixir/src/providers.ex)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# What a provider is, how a provider kind becomes a voxgig/plugin
# definition - and the four BUILT-IN kinds.
#
# A provider answers one question: "do you have this secret?" It returns
# the value, or nil to mean "ask the next one". Nothing else about a
# provider is visible to the caller - which is the point: an app reads
# `api.token` and never learns whether it came from the environment, a
# .env file, HashiCorp Vault, AWS, GCP, Azure or a boru vault.
#
# Two failure shapes, and they are never interchangeable. A store that does
# not hold the secret is a MISS (nil) - the chain carries on. A store that
# could not answer - bad credentials, unreachable host, missing
# configuration - is an ERROR: falling through there would quietly reach
# for a weaker store.
#
# THIS MODULE OPENS NO SOCKET, SIGNS NOTHING AND SPAWNS NOTHING. What
# makes a kind built in is that it needs nothing of the platform beyond
# reading a local file; every kind that opens a socket, signs a request or
# spawns a process is a voxgig/plugin definition under plugins/, its own
# module, loaded only by a program that names it. `elixirc` proves it:
# `make check-core` compiles src/ alone, and a call into a module that is
# not there is a warning this repository treats as an error
# (docs/design/plugin-providers.md).
#
# A port of typescript/src/provider/support.ts and
# typescript/src/provider/builtin.ts, which are canonical.

defmodule Sekreto.AuthSpec do
  @moduledoc """
  Logging in to a vault instead of being handed a token. `method` is
  `kubernetes` or `approle`; `mount` defaults to the method name.
  """

  defstruct method: "",
            mount: "",
            # kubernetes: the Vault role to log in as.
            role: "",
            # kubernetes: the service-account JWT itself (tests).
            jwt: "",
            # kubernetes: where the JWT lives; the pod path by default.
            jwtfile: "",
            # approle: the role and secret ids.
            roleid: "",
            secretid: ""
end

# Printed without its credentials.
#
# The derived inspection prints every field, so `Logger.error("bad chain:
# #{inspect(specs)}")` - which is what someone writes when a chain will not
# build - would put the service-account JWT and the AppRole secret id in
# the log. Fields that hold a credential report whether they are set, never
# what they are.
defimpl Inspect, for: Sekreto.AuthSpec do
  def inspect(spec, _opts) do
    Inspect.Algebra.concat([
      "AuthSpec(method=#{spec.method}, mount=#{spec.mount}, role=#{spec.role}",
      ", jwtfile=#{spec.jwtfile}, roleid=#{spec.roleid}",
      ", jwt=#{Sekreto.Providers.setornot(spec.jwt)}",
      ", secretid=#{Sekreto.Providers.setornot(spec.secretid)})"
    ])
  end
end

defmodule Sekreto.ProviderSpec do
  @moduledoc """
  The declarative form of a provider, as used in config and in the shared
  spec. `kind` picks the provider; everything else is that kind's own.

  Every text field defaults to the empty string: "not configured" and
  "configured empty" mean the same thing everywhere in this library.
  """

  defstruct kind: "",
            # The store name `Sekreto.getfrom` addresses. Defaults to `kind`.
            name: "",
            prefix: "",
            # dotenv: the file to read. secretspec: the declaration to read.
            file: "",
            # memory: literal values, keyed like environment variables, in
            # order - a list of {key, value} pairs, not a map.
            values: [],
            # file: the directory of one-secret-per-file entries.
            dir: "",
            # hashicorp / boru (wire) / gcp / 1password / doppler /
            # infisical: the base URL.
            addr: "",
            # hashicorp / boru (wire) / gcp / azure / 1password / doppler /
            # infisical: the token.
            token: "",
            # hashicorp / boru (wire): the KV mount (default `secret`).
            mount: "",
            # hashicorp: KV engine version, 1 or 2 (default 2).
            kv: nil,
            # hashicorp: Vault Enterprise namespace (X-Vault-Namespace).
            vaultnamespace: "",
            # hashicorp: log in for a token instead of being handed one.
            auth: nil,
            # boru / secretspec: the executable to run.
            command: "",
            # secretspec: the profile to read (`--profile`).
            profile: "",
            # secretspec: which of ITS backends to read from (`--provider`),
            # e.g. `keyring` or `dotenv://.env`. Named `backend` here
            # because `provider` already means a sekreto provider.
            backend: "",
            # secretspec: the audit reason recorded for the read
            # (`--reason`). SecretSpec refuses to read without one.
            reason: "",
            # boru: the namespace qualifying the alias.
            namespace: "",
            # boru: the vault home, passed as BORU_HOME.
            home: "",
            # aws: region and credentials; the standard AWS_* variables
            # fill the rest.
            region: "",
            keyid: "",
            secret: "",
            session: "",
            # gcp / doppler / infisical: the project, however that store
            # names it.
            project: "",
            # azure: the Key Vault name or full URL. 1password: the vault
            # name or id.
            vault: "",
            # azure: client-credential login. infisical: universal-auth.
            tenant: "",
            clientid: "",
            clientsecret: "",
            # azure: where to log in / where IMDS answers. gcp: the
            # metadata server.
            loginaddr: "",
            imdsaddr: "",
            metadataaddr: "",
            # azure: the Key Vault API version (default 7.4).
            apiversion: "",
            # doppler: the config slug (with `project`).
            config: "",
            # infisical: the environment slug and secret path.
            environment: "",
            path: ""
end

# Printed without its credentials. See the AuthSpec implementation: the
# derived one would put the Vault token, the AWS secret access key and the
# Azure client secret into whatever formatted it.
defimpl Inspect, for: Sekreto.ProviderSpec do
  def inspect(spec, opts) do
    Inspect.Algebra.concat([
      "ProviderSpec(kind=#{spec.kind}, name=#{spec.name}, addr=#{spec.addr}",
      ", token=#{Sekreto.Providers.setornot(spec.token)}",
      ", secret=#{Sekreto.Providers.setornot(spec.secret)}",
      ", clientsecret=#{Sekreto.Providers.setornot(spec.clientsecret)}",
      ", auth=",
      if(nil == spec.auth, do: "nil", else: Inspect.inspect(spec.auth, opts)),
      ")"
    ])
  end
end

defmodule Sekreto.Providers do
  @moduledoc """
  Provider support, and the four built-in provider kinds.

  A provider kind is a voxgig/plugin `Definition`, and `providerplugin/2`
  is the whole bridge between the two libraries - the four kinds below are
  made with it, the ten under plugins/ are made with it, and so is a
  caller's own.
  """

  alias Sekreto.AuthSpec
  alias Sekreto.Cell
  alias Sekreto.Error
  alias Voxgig.Plugin.Inst
  alias Voxgig.Plugin.Types

  @doc "What a credential field reports about itself."
  def setornot(value), do: if("" == value or nil == value, do: "[unset]", else: "[set]")

  @doc """
  An environment variable, or the empty string.

  Kept here rather than under plugins/ although only the aws and gcp kinds
  read one: `System.get_env/1` is what the built-in `env` kind already
  calls, so this reaches nothing the core does not reach anyway.
  """
  def getenv(name), do: System.get_env(name) || ""

  @doc "The first candidate that is set and non-empty, or the empty string."
  def first(candidates), do: Enum.find(candidates, "", fn value -> is_binary(value) and "" != value end)

  # ------------------------------------------------------------ addresses

  @doc """
  An address with any userinfo replaced by `[redacted]`, for messages.

  Every refusal below names the address it refused, and one of them fires
  precisely because the address carries a credential - so printing it
  verbatim would write the password to stderr and into the logs. It cannot
  be cleaned up afterwards either: that password was never resolved as a
  secret, so `redact` has never seen it and never will. The host is what a
  reader needs to identify which chain entry is at fault; the userinfo is
  not.
  """
  def safeaddr(addr) do
    case :binary.match(addr, "://") do
      :nomatch ->
        addr

      {mark, _len} ->
        rest = binary_part(addr, mark + 3, byte_size(addr) - mark - 3)
        authority = authorityof(rest)

        case :binary.matches(authority, "@") do
          [] ->
            addr

          found ->
            {at, _len} = List.last(found)

            binary_part(addr, 0, mark + 3) <>
              "[redacted]" <>
              binary_part(addr, mark + 3 + at, byte_size(addr) - mark - 3 - at)
        end
    end
  end

  # The authority ends at `/`, `?` or `#` - and NOT at `\`, so a client
  # that also breaks on a backslash (WHATWG does) can only ever see a
  # SHORTER host than this does.
  defp authorityof(rest) do
    case cutat(rest, [?/, ??, ?#], 0) do
      nil -> rest
      at -> binary_part(rest, 0, at)
    end
  end

  defp cutat(text, chars, at) do
    case text do
      <<_::binary-size(at), ch, _::binary>> ->
        if ch in chars, do: at, else: cutat(text, chars, at + 1)

      _other ->
        nil
    end
  end

  @doc """
  Refuse to send a secret-bearing credential in the clear.

  A vault API is HTTPS in any real deployment; plaintext is a dev-mode
  convenience. Sending a token over http to anything but the local machine
  puts both the token and the secret it fetches on the wire for anyone on
  the path, so sekreto will not do it. Loopback stays allowed: that is
  `vault server -dev`, `boru vault serve`, and this repository's own test
  harness.

  The address is read by hand, in the same handful of steps in every port,
  rather than by each platform's URL parser. A dozen parsers disagree about
  malformed input - where userinfo ends, whether `0177.0.0.1` is loopback,
  what an unclosed bracket means - and a check that answers differently in
  different ports is not a check.
  """
  def checkaddr(addr) do
    scheme =
      cond do
        String.starts_with?(addr, "https://") -> "https://"
        String.starts_with?(addr, "http://") -> "http://"
        true -> raise Error, message: "sekreto: not an http(s) address: " <> safeaddr(addr)
      end

    rest = binary_part(addr, byte_size(scheme), byte_size(addr) - byte_size(scheme))
    authority = authorityof(rest)

    # Userinfo is refused outright rather than parsed around, and on https
    # as well as http. No store this library speaks authenticates by
    # userinfo - they take a token or a signature - so an address carrying
    # one is a mistake at best. At worst it is the attack this whole
    # function exists to stop: `http://localhost:8200@evil.example.com/` is
    # a request to evil.example.com that reads, to anything that splits the
    # authority on ':', as loopback.
    if String.contains?(authority, "@") do
      raise Error,
        message: "sekreto: refusing an address with embedded credentials: " <> safeaddr(addr)
    end

    # An opening bracket with no closing one is not an address at all.
    if String.starts_with?(authority, "[") and not String.contains?(authority, "]") do
      raise Error, message: "sekreto: not a valid http(s) address: " <> safeaddr(addr)
    end

    if "https://" != scheme do
      # A bracketed IPv6 literal keeps its brackets. Splitting the
      # authority on the first colon yields '[', so `http://[::1]:8200`
      # could never match - which made the '[::1]' entry below unreachable,
      # and refused a legitimate local vault.
      host =
        if String.starts_with?(authority, "[") do
          {at, _len} = :binary.match(authority, "]")
          binary_part(authority, 0, at + 1)
        else
          authority |> :binary.split(":") |> hd()
        end

      # Nothing is normalised: `0177.0.0.1`, `2130706433` and
      # `[::ffff:127.0.0.1]` are refused rather than guessed at.
      if String.downcase(host, :ascii) not in ["localhost", "127.0.0.1", "::1", "[::1]"] do
        raise Error,
          message:
            "sekreto: refusing to send a token in plaintext to " <>
              safeaddr(addr) <> " (use https)"
      end
    end

    :ok
  end

  # --------------------------------------------------------- the built-in
  #
  # "Built in" means: needs nothing of the platform beyond reading a local
  # file - no socket, no TLS, no crypto, no child process.

  @doc "Environment variables: `api.token` from `API_TOKEN`."
  def env(prefix \\ "", source \\ nil) do
    %{
      lookup: fn name ->
        key = Sekreto.envkey(name, prefix)
        if nil == source, do: System.get_env(key), else: Sekreto.pairget(source, key)
      end,
      describe: fn -> if "" == prefix, do: "env", else: "env:" <> prefix end
    }
  end

  @doc """
  Literal values, keyed like environment variables. The spec uses this to
  test chain behaviour without touching the outside world.
  """
  def memory(values \\ [], prefix \\ "") do
    %{
      lookup: fn name -> Sekreto.pairget(values, Sekreto.envkey(name, prefix)) end,
      describe: fn -> if "" == prefix, do: "memory", else: "memory:" <> prefix end
    }
  end

  @doc """
  A `.env` file, read once, keyed exactly like the environment.

  Read LAZILY: the `stores` corpus group puts a dotenv provider in a chain
  and never looks anything up, so an eager constructor would read whatever
  `.env` happened to sit in the working directory.
  """
  def dotenv(file, prefix \\ "") do
    cell = Cell.new(:unloaded)

    %{
      lookup: fn name ->
        values =
          case Cell.get(cell) do
            :unloaded ->
              loaded = loaddotenv(file)
              Cell.put(cell, loaded)
              loaded

            loaded ->
              loaded
          end

        Sekreto.pairget(values, Sekreto.envkey(name, prefix))
      end,
      describe: fn -> "dotenv:" <> file end
    }
  end

  defp loaddotenv(file) do
    case File.read(file) do
      {:ok, text} ->
        Sekreto.parsedotenv(text)

      # An absent file - or an absent directory - means "no secrets here",
      # exactly like the file provider. Anything else - permission denied,
      # an unreadable mount - is an error, because answering a miss there
      # falls silently through to a weaker store.
      {:error, why} when why in [:enoent, :enotdir] ->
        []

      {:error, why} ->
        raise Error,
          message: "sekreto: dotenv provider cannot read " <> file <> ": " <> errtext(why)
    end
  end

  defp errtext(why), do: to_string(:file.format_error(why))

  @doc """
  A directory of one-secret-per-file entries, keyed like the environment:
  `api.token` reads `<dir>/API_TOKEN`.

  This is the shape of a mounted Kubernetes Secret, a Docker or Swarm
  secret, and a systemd credentials directory, so those all work with no
  further configuration. Read on every lookup, never cached. One trailing
  newline is stripped - tools that write these files disagree about it, and
  a newline is never part of a secret on purpose.
  """
  def file(dir, prefix \\ "") do
    %{
      lookup: fn name ->
        path = Path.join(dir, Sekreto.envkey(name, prefix))

        case File.read(path) do
          {:ok, text} ->
            cond do
              String.ends_with?(text, "\r\n") -> Sekreto.dropsuffix(text, "\r\n")
              String.ends_with?(text, "\n") -> Sekreto.dropsuffix(text, "\n")
              true -> text
            end

          {:error, why} when why in [:enoent, :enotdir] ->
            nil

          {:error, why} ->
            raise Error,
              message: "sekreto: file provider cannot read " <> path <> ": " <> errtext(why)
        end
      end,
      describe: fn -> "file:" <> dir end
    }
  end

  # ------------------------------ providers as voxgig/plugin definitions

  @doc """
  The export key under which a provider definition publishes the provider
  it built. `Sekreto` reads `<ref>/provider` off the host.
  """
  def provider_export, do: "provider"

  @doc """
  The voxgig/plugin error code a `Sekreto.Error` travels under when it is
  raised inside a definition's `define`.

  plugin wraps a code-less error raised by a callback as
  `plugin_define_failed`, and keeps an error that already carries a code. A
  provider that refuses its own configuration - `kv: 3`, a missing project
  - raises a `Sekreto.Error`, and that message is pinned by the spec byte
  for byte, so it must come back out of the host exactly as it went in.
  `providerplugin/2` gives it this code on the way in; `Sekreto` turns it
  back into a `Sekreto.Error` on the way out.
  """
  def error_code, do: "sekreto_error"

  @doc """
  A provider kind, as a voxgig/plugin definition.

  This is the whole bridge between the two libraries. The definition's
  `name` is the `kind` a spec names; its `define` reads the spec as
  `Inst.options/1`, builds the provider with `make`, and exports it.
  Nothing runs at `activate`: a provider opens nothing until its first
  lookup, so there is nothing to capture - a provider that does hold a
  resource acquires it there and lets the instance scope unwind it.

  Every built-in and every plugin is made this way, so a custom provider
  kind is one call:

      Sekreto.providerplugin("mystore", fn spec ->
        %{lookup: fn name -> ... end, describe: fn -> "mystore" end}
      end)

  A definition is a plain map with STRING keys, which is what voxgig/plugin
  reads a catalog entry as.
  """
  def providerplugin(kind, make) do
    %{
      "name" => kind,
      "define" => fn inst ->
        provider =
          try do
            make.(Inst.options(inst))
          rescue
            err in Error ->
              # Re-raised with a code, so that plugin keeps the message
              # rather than wrapping it as `plugin_define_failed`.
              Types.fail(error_code(), Exception.message(err), %{
                "ref" => Inst.ref(inst),
                "cause" => Exception.message(err)
              })
          end

        Inst.export(inst, provider_export(), provider)
      end
    }
  end

  @doc """
  The four built-in provider kinds - the same four in every port.

  What makes a kind built in is that it needs nothing of the platform
  beyond reading a local file: no socket, no TLS, no crypto, no child
  process. A chain of these four works with no plugin loaded at all.
  """
  def builtins do
    [
      providerplugin("env", fn spec -> env(spec.prefix) end),
      providerplugin("memory", fn spec -> memory(spec.values, spec.prefix) end),
      providerplugin("dotenv", fn spec -> dotenv(first([spec.file, ".env"]), spec.prefix) end),
      providerplugin("file", fn spec -> file(spec.dir, spec.prefix) end)
    ]
  end

  @doc """
  Every kind this library ships, built in or as a plugin, so that an
  unknown kind can be told from a plugin that was not passed in.
  """
  def kinds do
    %{
      builtin: ["env", "memory", "dotenv", "file"],
      plugin: [
        "hashicorp",
        "boru",
        "awssecrets",
        "awsparams",
        "gcpsecrets",
        "azuresecrets",
        "onepassword",
        "doppler",
        "infisical",
        "secretspec"
      ]
    }
  end

  @doc "An AuthSpec, for callers building one by hand."
  def authspec(fields \\ []), do: struct(AuthSpec, fields)
end
