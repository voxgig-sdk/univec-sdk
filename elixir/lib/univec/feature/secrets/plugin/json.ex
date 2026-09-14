# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (elixir/lib/voxgig_plugin/json.ex)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
defmodule Voxgig.Plugin.Json do
  @moduledoc """
  The JSON parser, and the only one this port has.

  NO JASON, NO POISON (section 16). The library is allowed exactly one
  runtime dependency, `voxgig/struct`, which has no elixir port; everything
  else is the standard library. Parsing the corpus is a hundred and fifty
  lines, and a hundred and fifty lines is cheaper than a hex dependency
  every embedding host inherits - and it keeps this port free of a
  `mix.exs` deps list entirely.
  """

  alias Voxgig.Plugin.Types

  @doc "Parse a JSON document. Raises on malformed input."
  def parse(text) do
    {value, rest} = value(skipws(text))

    case skipws(rest) do
      "" -> value
      trailing -> raise ArgumentError, "trailing input: #{String.slice(trailing, 0, 20)}"
    end
  end

  defdelegate encode(value), to: Types

  defp skipws(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r], do: skipws(rest)
  defp skipws(text), do: text

  defp value("{" <> rest), do: map(skipws(rest), %{})
  defp value("[" <> rest), do: list(skipws(rest), [])
  defp value("\"" <> _ = text), do: string(text)
  defp value("true" <> rest), do: {true, rest}
  defp value("false" <> rest), do: {false, rest}
  defp value("null" <> rest), do: {nil, rest}
  defp value(text), do: number(text)

  defp map("}" <> rest, acc), do: {acc, rest}

  defp map(text, acc) do
    {key, rest} = string(skipws(text))

    rest =
      case skipws(rest) do
        ":" <> more -> more
        other -> raise ArgumentError, "expected ':' at #{String.slice(other, 0, 20)}"
      end

    {v, rest} = value(skipws(rest))

    case skipws(rest) do
      "," <> more -> map(skipws(more), Map.put(acc, key, v))
      "}" <> more -> {Map.put(acc, key, v), more}
      other -> raise ArgumentError, "expected ',' or '}' at #{String.slice(other, 0, 20)}"
    end
  end

  defp list("]" <> rest, acc), do: {Enum.reverse(acc), rest}

  defp list(text, acc) do
    {v, rest} = value(skipws(text))

    case skipws(rest) do
      "," <> more -> list(skipws(more), [v | acc])
      "]" <> more -> {Enum.reverse([v | acc]), more}
      other -> raise ArgumentError, "expected ',' or ']' at #{String.slice(other, 0, 20)}"
    end
  end

  defp string("\"" <> rest), do: chars(rest, [])
  defp string(other), do: raise(ArgumentError, "expected a string at #{String.slice(other, 0, 20)}")

  defp chars("\"" <> rest, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}
  defp chars("\\\"" <> rest, acc), do: chars(rest, ["\"" | acc])
  defp chars("\\\\" <> rest, acc), do: chars(rest, ["\\" | acc])
  defp chars("\\/" <> rest, acc), do: chars(rest, ["/" | acc])
  defp chars("\\b" <> rest, acc), do: chars(rest, ["\b" | acc])
  defp chars("\\f" <> rest, acc), do: chars(rest, ["\f" | acc])
  defp chars("\\n" <> rest, acc), do: chars(rest, ["\n" | acc])
  defp chars("\\r" <> rest, acc), do: chars(rest, ["\r" | acc])
  defp chars("\\t" <> rest, acc), do: chars(rest, ["\t" | acc])

  defp chars("\\u" <> <<hex::binary-size(4), rest::binary>>, acc) do
    code = String.to_integer(hex, 16)

    # A surrogate PAIR is two escapes, and elixir strings are UTF-8 - so
    # the halves are joined here rather than appended as they arrive.
    case {code, rest} do
      {c, "\\u" <> <<low::binary-size(4), more::binary>>} when c >= 0xD800 and c < 0xDC00 ->
        lowcode = String.to_integer(low, 16)

        if lowcode >= 0xDC00 and lowcode < 0xE000 do
          joined = 0x10000 + (c - 0xD800) * 0x400 + (lowcode - 0xDC00)
          chars(more, [<<joined::utf8>> | acc])
        else
          chars(rest, [<<c::utf8>> | acc])
        end

      _ ->
        chars(rest, [<<code::utf8>> | acc])
    end
  end

  defp chars(<<c::utf8, rest::binary>>, acc), do: chars(rest, [<<c::utf8>> | acc])
  defp chars("", _), do: raise(ArgumentError, "unterminated string")

  defp number(text) do
    {digits, rest} = numchars(text, [])
    body = digits |> Enum.reverse() |> IO.iodata_to_binary()

    cond do
      "" == body ->
        raise ArgumentError, "unexpected input at #{String.slice(text, 0, 20)}"

      String.contains?(body, [".", "e", "E"]) ->
        {String.to_float(body), rest}

      true ->
        {String.to_integer(body), rest}
    end
  end

  defp numchars(<<c, rest::binary>>, acc)
       when c in ?0..?9 or c in [?-, ?+, ?., ?e, ?E] do
    numchars(rest, [<<c>> | acc])
  end

  defp numchars(text, acc), do: {acc, text}
end
