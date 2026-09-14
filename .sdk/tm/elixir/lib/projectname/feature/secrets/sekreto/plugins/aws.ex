# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (elixir/plugins/aws.ex)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# AWS Secrets Manager and SSM Parameter Store, as sekreto plugins.
#
# TWO KINDS IN ONE MODULE, because they share a signer: `awssecrets` and
# `awsparams` differ in the API they call and in nothing else. This is the
# only plugin that reaches a hash function, through
# `Sekreto.Plugins.Sigv4` - which is why the core of no port imports one.
#
# A port of typescript/plugins/aws.ts, which is canonical.

defmodule Sekreto.Plugins.Aws do
  @moduledoc """
  The `awssecrets` and `awsparams` provider kinds.

  A plugin module: nothing under `src/` names it, and a chain that does not
  name this kind never loads it. See docs/design/plugin-providers.md.
  """

  alias Sekreto.Error
  alias Sekreto.Json
  alias Sekreto.Plugins.Httpjson
  alias Sekreto.Plugins.Signing
  alias Sekreto.Plugins.Sigv4
  alias Sekreto.ProviderSpec
  alias Sekreto.Providers

  @doc """
  The `awssecrets` provider kind, as a voxgig/plugin definition.

  The calling project passes it to the constructor, and only then can a
  chain name the kind:

      Sekreto.new(chain, plugins: [Sekreto.Plugins.Aws.awssecrets()])
  """
  def awssecrets, do: Providers.providerplugin("awssecrets", &secretsfromspec/1)

  @doc """
  The `awsparams` provider kind, as a voxgig/plugin definition.

  The calling project passes it to the constructor, and only then can a
  chain name the kind:

      Sekreto.new(chain, plugins: [Sekreto.Plugins.Aws.awsparams()])
  """
  def awsparams, do: Providers.providerplugin("awsparams", &paramsfromspec/1)

  @doc "The `YYYYMMDDTHHMMSSZ` timestamp SigV4 wants, for now."
  def awsnow do
    {{year, month, day}, {hour, minute, second}} = :calendar.universal_time()

    pad = fn value, width ->
      value |> Integer.to_string() |> String.pad_leading(width, "0")
    end

    pad.(year, 4) <>
      pad.(month, 2) <>
      pad.(day, 2) <> "T" <> pad.(hour, 2) <> pad.(minute, 2) <> pad.(second, 2) <> "Z"
  end

  @doc """
  Region and credentials, from config first and the standard AWS_*
  environment variables second - those are AWS's own convention, and a pod
  or CI job that has them set should just work. Missing either is an error:
  an AWS store with no credentials could not answer.
  """
  def awsauth(region, keyid, secret, session) do
    useregion =
      Providers.first([
        region,
        Providers.getenv("AWS_REGION"),
        Providers.getenv("AWS_DEFAULT_REGION")
      ])
    usekeyid = Providers.first([keyid, Providers.getenv("AWS_ACCESS_KEY_ID")])
    usesecret = Providers.first([secret, Providers.getenv("AWS_SECRET_ACCESS_KEY")])
    usesession = Providers.first([session, Providers.getenv("AWS_SESSION_TOKEN")])

    if "" == useregion do
      raise Error, message: "sekreto: aws: no region (set region or AWS_REGION)"
    end

    if "" == usekeyid or "" == usesecret do
      raise Error,
        message:
          "sekreto: aws: no credentials" <>
            " (set keyid/secret or AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY)"
    end

    %{region: useregion, keyid: usekeyid, secret: usesecret, session: usesession}
  end

  @doc "One signed call to an AWS JSON-1.1 API."
  def awscall(opts, service, target, payload) do
    auth = awsauth(opts.region, opts.keyid, opts.secret, opts.session)

    # The China partition lives under its own suffix; every other
    # commercial region is plain amazonaws.com.
    suffix =
      if String.starts_with?(auth.region, "cn-"),
        do: ".amazonaws.com.cn",
        else: ".amazonaws.com"

    useaddr = Providers.first([opts.addr, "https://" <> service <> "." <> auth.region <> suffix])
    Providers.checkaddr(useaddr)

    url = Httpjson.trimslash(useaddr) <> "/"

    extras = [
      {"content-type", "application/x-amz-json-1.1"},
      {"x-amz-target", target}
    ]

    signed =
      Sigv4.sigv4(%Signing{
        method: "POST",
        url: url,
        service: service,
        region: auth.region,
        keyid: auth.keyid,
        secret: auth.secret,
        datetime: awsnow(),
        headers: extras,
        body: payload,
        session: auth.session
      })

    Httpjson.fetchjson("POST", url, extras ++ signed, payload)
  end

  @doc """
  Does this AWS error body name one of the not-found types? Those are a
  miss; every other failure is a store that could not answer.
  """
  def awsmiss(body, types) do
    case Json.asstr(Json.dig(body, ["__type"])) do
      :none -> false
      errtype -> Enum.any?(types, fn want -> String.contains?(errtype, want) end)
    end
  end

  @doc """
  AWS Secrets Manager.

  `api.token` reads the secret named `api` (the vaultref path, so
  `db.pass.main` reads `db/pass`) and takes the `token` field of its JSON
  SecretString - the AWS idiom of one JSON map per secret. A SecretString
  that is not JSON is the value itself, under the conventional field
  `value`.
  """
  def awssecrets(opts) do
    %{
      lookup: fn name ->
        ref = Sekreto.vaultref(name)

        res =
          awscall(
            opts,
            "secretsmanager",
            "secretsmanager.GetSecretValue",
            Json.stringify(Json.obj([{"SecretId", Json.str(ref.path)}]))
          )

        cond do
          400 == res.status and awsmiss(res.body, ["ResourceNotFoundException"]) ->
            nil

          200 != res.status ->
            raise Error,
              message: "sekreto: aws secretsmanager error: " <> Httpjson.tostr(res.status)

          true ->
            case Json.asstr(Json.dig(res.body, ["SecretString"])) do
              :none ->
                # A binary secret has no fields to address; only the
                # conventional `value` field can mean "the bytes
                # themselves".
                bin = Json.asstr(Json.dig(res.body, ["SecretBinary"]))

                if :none != bin and "value" == ref.field do
                  case Httpjson.unbase64(bin) do
                    :error ->
                      raise Error, message: "sekreto: aws secretsmanager: undecodable secret"

                    text ->
                      text
                  end
                end

              text ->
                case Json.parse(text) do
                  {:ok, {:obj, _pairs} = parsed} ->
                    Httpjson.nonone(Json.text(Json.dig(parsed, [ref.field])))

                  # A plain-string secret is the whole value; it has no
                  # named fields.
                  _other ->
                    if "value" == ref.field, do: text
                end
            end
        end
      end,
      # Config only, never the environment: describe() feeds the spec's
      # sources group, which must answer the same everywhere.
      describe: fn -> "awssecrets:" <> opts.region end
    }
  end

  @doc """
  AWS SSM Parameter Store.

  `db.pass.main` reads the parameter `/db/pass/main` (under an optional
  prefix path), decrypted. Parameter Store carries flat strings, so there
  is no field indirection.
  """
  def awsparams(opts, prefix) do
    %{
      lookup: fn name ->
        payload =
          Json.obj([
            {"Name", Json.str(Sekreto.awsparam(name, prefix))},
            {"WithDecryption", Json.bool(true)}
          ])

        res = awscall(opts, "ssm", "AmazonSSM.GetParameter", Json.stringify(payload))

        cond do
          400 == res.status and awsmiss(res.body, ["ParameterNotFound"]) ->
            nil

          200 != res.status ->
            raise Error, message: "sekreto: aws ssm error: " <> Httpjson.tostr(res.status)

          true ->
            Httpjson.nonone(Json.text(Json.dig(res.body, ["Parameter", "Value"])))
        end
      end,
      describe: fn -> "awsparams:" <> opts.region <> prefix end
    }
  end

  defp secretsfromspec(%ProviderSpec{} = spec), do: awssecrets(awsopts(spec))

  defp paramsfromspec(%ProviderSpec{} = spec), do: awsparams(awsopts(spec), spec.prefix)

  # Region and credentials, shared by both stores: they differ in the API
  # they call, never in how they are signed.
  defp awsopts(%ProviderSpec{} = spec) do
    %{
      region: spec.region,
      keyid: spec.keyid,
      secret: spec.secret,
      session: spec.session,
      addr: spec.addr
    }
  end
end
