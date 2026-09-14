# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (elixir/plugins/httpjson.ex)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# The round-trip every remote store shares - and OUTSIDE THE CORE with the
# client under it.
#
# Eight of the ten plugin kinds read a vault over HTTPS, and all eight
# want the same three things: one JSON round-trip whose failures are
# never a miss, a login token renewed shortly before its lease runs out,
# and a handful of conversions between a JSON value and the string a
# secret is. Written once here rather than eight times, and never in the
# core: a chain of the four built-ins must not link an HTTP client.
#
# `runcmd` is NOT here. The two kinds that read a store through its own
# CLI - boru and secretspec - reach `Sekreto.Plugins.Proc` instead, so
# that secretspec, which opens no socket at all, loads no socket code.

defmodule Sekreto.Plugins.Httpjson do
  @moduledoc """
  The shared plugin edge: one JSON round-trip, token renewal, and the
  small conversions the vault clients share.

  A plugin module: nothing under `src/` names it. See
  docs/design/plugin-providers.md.
  """

  alias Sekreto.Cell
  alias Sekreto.Error
  alias Sekreto.Json
  alias Sekreto.Plugins.Http

  @doc """
  The renewal time of a token that has no expiry: never.

  A configured token is kept forever; only a logged-in one carries a
  lease. Answered by a function rather than held in a module attribute,
  because every plugin that keeps a token cell needs the same value and
  an attribute cannot cross a module.
  """
  def never, do: 9_223_372_036_854_775_807

  @doc "An address without its trailing slash."
  def trimslash(text), do: Sekreto.dropsuffix(text, "/")

  @doc """
  One JSON round-trip. Answers `%{status: integer, body: json | :none}`.

  Network failure is always an error - an unreachable store is a store that
  could not answer. A success status promised JSON, so a 200 whose body
  does not parse is a store that answered incoherently, and treating that
  as a miss would fall through to a weaker store. Error statuses may carry
  any body at all: they are decided on status alone.
  """
  def fetchjson(method, url, headers \\ [], body \\ nil) do
    answer = Http.fetch(method, url, headers, body)

    parsed =
      case Json.parse(answer.body) do
        {:ok, value} -> value
        :error -> :none
      end

    if 200 == answer.status and :none == parsed do
      raise Error, message: "sekreto: malformed response from " <> Http.bare(url)
    end

    %{status: answer.status, body: parsed}
  end

  @doc """
  When a logged-in token must be renewed, from its expiry in seconds (a
  JSON number, or a string as Azure IMDS sends it): now + max(seconds - 60,
  1). A missing or zero expiry means never renew.
  """
  def renewtime(expires) do
    seconds =
      case expires do
        {:num, value} ->
          value

        {:str, value} ->
          case Float.parse(value) do
            {value, _rest} -> value
            :error -> 0.0
          end

        _other ->
          0.0
      end

    if 0 >= seconds do
      never()
    else
      System.system_time(:millisecond) + trunc(max(seconds - 60, 1.0) * 1000)
    end
  end

  @doc """
  Is this token cell due for renewal? A cell holding no token has never
  logged in; one past its renewal time is about to expire.
  """
  def expired?(cell) do
    held = Cell.get(cell)
    "" == held.token or System.system_time(:millisecond) >= held.renewat
  end

  @doc """
  Strict base64.

  Whitespace is stripped first - the canonical function accepts embedded
  newlines - and then anything outside the standard alphabet, or a length
  that is not a multiple of four, is REFUSED. A lenient decoder silently
  skips what it does not recognise and hands back plausible bytes for a
  corrupted payload, which then get returned as the secret.
  """
  def unbase64(text) do
    stripped = String.replace(text, ~r/\s/, "")

    case Base.decode64(stripped, padding: true) do
      {:ok, bytes} -> bytes
      :error -> :error
    end
  end

  @doc "A JSON accessor's `:none` as the miss the chain reads: nil."
  def nonone(:none), do: nil
  def nonone(value), do: value

  @doc "Any value as text, for a message: a status code, a kv version."
  def tostr(value) when is_binary(value), do: value
  def tostr(value) when is_integer(value), do: Integer.to_string(value)
  def tostr(value) when is_float(value), do: Json.numstr(value)
  def tostr(value), do: inspect(value)
end
