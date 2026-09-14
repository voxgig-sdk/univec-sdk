# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (elixir/plugins/sigv4.ex)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# AWS Signature Version 4, hand-rolled - and OUTSIDE THE CORE, because it
# is the library's one cryptographic edge. Only the two aws kinds sign
# anything, which is why the core of no port imports a hash function:
# `:crypto` is reached from here and from nowhere else.
#
# The AWS providers need exactly one thing from the AWS SDK - request
# signing - and taking the SDK for it would break the no-dependency rule
# that keeps the ports honest. SigV4 is a stable, published algorithm built
# from HMAC-SHA256, which OTP's `:crypto` already has.
#
# `sigv4` is pure: the caller passes the timestamp, so the same input
# yields the same signature everywhere. That is what lets the shared spec
# carry known-answer cases that all ports must reproduce bit-for-bit, and
# lets the integration mock recompute the signature server-side.
#
# THE URL HALF IS NOT HERE. `uriescape`, `uridecode`, `urlhost` and
# `urlparts` live in `Sekreto.Plugins.Http`, because four kinds that sign
# nothing escape a query parameter and the HTTP client itself splits every
# URL it sends. Keeping them here would make every HTTPS kind reach the
# signer, and `:crypto` with it, for a string function. Ruby's port draws
# the same line, into its `httpjson`. The uppercase-hex rule that pairs
# with src/json.ex's lowercase one travelled with `uriescape`; the comment
# on it is there.
#
# A port of typescript/plugins/sigv4.ts, which is canonical.

defmodule Sekreto.Plugins.Signing do
  @moduledoc """
  One request to sign - the same declarative shape the shared spec uses.

  `datetime` is `YYYYMMDDTHHMMSSZ`, and it is the caller's, so that signing
  is a pure function of its input.
  """

  defstruct method: "",
            url: "",
            service: "",
            region: "",
            keyid: "",
            secret: "",
            datetime: "",
            headers: [],
            body: "",
            session: ""
end

defmodule Sekreto.Plugins.Sigv4 do
  @moduledoc """
  AWS Signature Version 4.

  A plugin module: nothing under `src/` names it, and `:crypto` is
  reached from here alone. See docs/design/plugin-providers.md.
  """

  alias Sekreto.Plugins.Http
  alias Sekreto.Plugins.Signing

  @doc "Lowercase hex, two digits a byte."
  def hex(bytes), do: Base.encode16(bytes, case: :lower)

  @doc "SHA-256 of the UTF-8 text, as lowercase hex."
  def sha256hex(text), do: hex(:crypto.hash(:sha256, text))

  @doc "HMAC-SHA256, key first - PHP and Perl's stdlib take them the other way."
  def hmac(key, text), do: :crypto.mac(:hmac, :sha256, key, text)

  @doc """
  The canonical query string: each pair RFC 3986-escaped, sorted by escaped
  key then escaped value.
  """
  def canonicalquery(""), do: ""

  def canonicalquery(query) do
    query
    |> String.split("&")
    |> Enum.map(fn pair ->
      {key, value} =
        case :binary.split(pair, "=") do
          [only] -> {only, ""}
          [head, tail] -> {head, tail}
        end

      {Http.uriescape(Http.uridecode(key)), Http.uriescape(Http.uridecode(value))}
    end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {key, value} -> key <> "=" <> value end)
  end

  @doc """
  Sign one request. Answers the headers to attach: `authorization`,
  `x-amz-date`, and `x-amz-security-token` when a session token was given,
  in that order - the spec compares the result as a JSON object, and
  callers print it field by field.
  """
  def sigv4(%Signing{} = input) do
    date = binary_part(input.datetime, 0, 8)
    session = input.session || ""

    # Every header that will be signed: the caller's extras, plus host and
    # x-amz-date (and the session token when present), lower-cased and
    # trimmed the way the canonical form requires - AWS folds sequential
    # whitespace, spaces AND tabs, to one space before signing, so a header
    # like "a  b" must sign as "a b" or the service refuses it.
    #
    # The inserted three come last, so they win over a caller that named
    # one of them.
    folded =
      Enum.map(input.headers, fn {key, value} ->
        {String.downcase(key, :ascii), String.replace(String.trim(value), ~r/\s+/, " ")}
      end)

    folded = putheader(folded, "host", Http.urlhost(input.url))
    folded = putheader(folded, "x-amz-date", input.datetime)

    folded =
      if "" == session, do: folded, else: putheader(folded, "x-amz-security-token", session)

    headers = Enum.sort_by(folded, fn {key, _value} -> key end)

    canonicalheaders = Enum.map_join(headers, "", fn {key, value} -> key <> ":" <> value <> "\n" end)
    signedheaders = Enum.map_join(headers, ";", fn {key, _value} -> key end)

    {_scheme, _authority, rawpath, rawquery} = Http.urlparts(input.url)
    path = if "" == rawpath, do: "/", else: rawpath

    canonicalrequest =
      Enum.join(
        [
          String.upcase(input.method, :ascii),
          path,
          canonicalquery(rawquery),
          canonicalheaders,
          signedheaders,
          sha256hex(input.body)
        ],
        "\n"
      )

    scope = date <> "/" <> input.region <> "/" <> input.service <> "/aws4_request"

    stringtosign =
      Enum.join(
        ["AWS4-HMAC-SHA256", input.datetime, scope, sha256hex(canonicalrequest)],
        "\n"
      )

    kdate = hmac("AWS4" <> input.secret, date)
    kregion = hmac(kdate, input.region)
    kservice = hmac(kregion, input.service)
    ksigning = hmac(kservice, "aws4_request")
    signature = hex(hmac(ksigning, stringtosign))

    out = [
      {"authorization",
       "AWS4-HMAC-SHA256 Credential=" <>
         input.keyid <>
         "/" <> scope <> ", SignedHeaders=" <> signedheaders <> ", Signature=" <> signature},
      {"x-amz-date", input.datetime}
    ]

    if "" == session, do: out, else: out ++ [{"x-amz-security-token", session}]
  end

  # Replace in place if the key is there, else append: the caller's own
  # order is kept, and an inserted header wins over a caller's.
  defp putheader(pairs, key, value) do
    if List.keymember?(pairs, key, 0) do
      List.keyreplace(pairs, key, 0, {key, value})
    else
      pairs ++ [{key, value}]
    end
  end
end
