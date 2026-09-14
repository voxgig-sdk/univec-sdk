# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (elixir/src/json.ex)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# Minimal JSON support for sekreto.
#
# sekreto adds no third-party dependencies, so it carries just enough JSON
# to read a vault's answer and write the CLI's own line of output. It is
# deliberately not a general-purpose library.
#
# OTP 27 ships `:json` and Elixir 1.18 a `JSON` module. Neither is used,
# and neither is reached for conditionally: the OTP 25 that Ubuntu 24.04
# packages has no built-in JSON at all, so a port that used one where it
# found one would behave differently on two releases of the same runtime.
#
# Tagged tuples rather than plain Elixir values: a vault answering `null`,
# `false`, `0` and "no such key" means four different things, and a closed
# value model keeps them apart rather than by convention. `parse` answers
# `{:ok, value}` or `:error`, where `:error` means "this text is not JSON"
# and `{:ok, :null}` means "this text is the JSON literal null" - a
# distinction the callers of fetchjson need, since only the first is a
# malformed response.
#
# Objects are an ORDERED list of pairs, not a map: a payload's field order
# is signed, and Elixir maps have no order at all above 32 keys.
#
# IN THE CORE, THOUGH NO CORE MODULE CALLS IT. What makes a kind a plugin
# is a socket, a signature or a child process, and this reads a string:
# there is nothing here to keep out of a chain of built-ins, and the BEAM
# loads no module nothing calls. It stays because the CLI assembles its
# one line of output with `quotestr`, and seven plugin kinds parse a
# vault's answer with `parse` - one writer for both, so the escaping can
# only be got right or wrong once. java/src/Json.java and
# kotlin/src/Json.kt sit in their cores for the same reason.
#
# A port of typescript/src/Json.ts, which is canonical.

defmodule Sekreto.Json do
  @moduledoc "The JSON value model, parser and writer sekreto carries."

  # A response body arrives before any trust check has run, so `[[[[...`
  # must not be able to exhaust the stack.
  @maxdepth 128

  @typedoc """
  A JSON value. `:none` is not one: it is what the accessors below answer
  when there is nothing there at all, which JSON cannot say.
  """
  @type t ::
          :null
          | {:bool, boolean}
          | {:num, float}
          | {:str, binary}
          | {:arr, [t]}
          | {:obj, [{binary, t}]}

  # ------------------------------------------------------- constructors

  def str(value), do: {:str, value}

  def num(value), do: {:num, value / 1}

  def bool(value), do: {:bool, value}

  def arr(entries), do: {:arr, entries}

  @doc "An object, in the order given: a payload's field order is signed."
  def obj(pairs), do: {:obj, pairs}

  # ---------------------------------------------------------- accessors
  #
  # Each answers `:none` for the wrong type as well as for a missing value,
  # because every caller wants the same thing from both: `__type` must be a
  # string, a 1Password vault list must be an array, a Doppler config must
  # be an object.

  def asstr({:str, value}), do: value
  def asstr(_other), do: :none

  def asnum({:num, value}), do: value
  def asnum(_other), do: :none

  def asarr({:arr, value}), do: value
  def asarr(_other), do: :none

  def asobj({:obj, value}), do: value
  def asobj(_other), do: :none

  @doc "Walk nested objects; `:none` the moment a step is not there."
  def dig(value, keys) when is_list(keys) do
    Enum.reduce(keys, value, fn key, at ->
      case at do
        {:obj, pairs} ->
          case List.keyfind(pairs, key, 0) do
            {^key, found} -> found
            nil -> :none
          end

        _other ->
          :none
      end
    end)
  end

  @doc """
  This value as the text a caller would print, or `:none` when there is no
  value at all.

  A JSON null is "no value": every provider here treats it as a miss rather
  than as the string "null".
  """
  def text(:null), do: :none
  def text(:none), do: :none
  def text({:str, value}), do: value
  def text({:num, value}), do: numstr(value)
  def text({:bool, value}), do: if(value, do: "true", else: "false")
  def text(other), do: stringify(other)

  # ------------------------------------------------------------- writer

  @doc "Render a value as compact JSON."
  def stringify(:null), do: "null"
  def stringify(:none), do: "null"
  def stringify({:bool, value}), do: if(value, do: "true", else: "false")
  def stringify({:num, value}), do: numstr(value)
  def stringify({:str, value}), do: quotestr(value)
  def stringify({:arr, entries}), do: "[" <> Enum.map_join(entries, ",", &stringify/1) <> "]"

  def stringify({:obj, pairs}) do
    "{" <> Enum.map_join(pairs, ",", fn {key, value} -> quotestr(key) <> ":" <> stringify(value) end) <> "}"
  end

  @doc """
  Render a string as a JSON string literal, quotes included.

  Public because the CLI assembles its one line of output field by field:
  printing a map there is what has bitten port after port, since the
  language's own key order is not the one every other port prints.
  """
  def quotestr(text) when is_binary(text) do
    "\"" <> escape(text, []) <> "\""
  end

  defp escape(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp escape(<<ch::utf8, rest::binary>>, acc) do
    piece =
      case ch do
        ?" -> "\\\""
        ?\\ -> "\\\\"
        ?\n -> "\\n"
        ?\r -> "\\r"
        ?\t -> "\\t"
        # `/` is accepted on input but never escaped on output, and
        # non-ASCII is not escaped either.
        # LOWERCASE hex, and `String.downcase` is what makes it so:
        # Integer.to_string(11, 16) is "B" in Elixir, not "b". Every other
        # port emits lowercase here -- rust `\\u{:04x}`, kotlin, scala and
        # java `"\\u%04x"`, csharp `ToString("x4")` -- and the writer is
        # contract, so a port that disagreed would be the thing that is
        # wrong. Note the deliberate asymmetry with `uriescape` in
        # plugins/http.ex, where the SAME call must stay UPPERCASE:
        # percent-escapes are uppercase by specification. Two sites, one
        # call, opposite answers -- and since the split they are in two
        # directories, so each file names the other rather than relying
        # on proximity. `hexcase` in test/plugins_test.exs pins both
        # directions, because neither suite can see a flip: conformance
        # and integration both stay green either way.
        other when other < 0x20 ->
          "\\u" <>
            String.pad_leading(String.downcase(Integer.to_string(other, 16), :ascii), 4, "0")
        other -> <<other::utf8>>
      end

    escape(rest, [piece | acc])
  end

  @doc """
  Render a number the way every other port does: a whole number has no
  fractional tail, so a JSON `1` read back and printed stays `1`.
  """
  def numstr(value) do
    asfloat = value / 1

    if asfloat == Float.round(asfloat) and 9_007_199_254_740_992.0 > abs(asfloat) do
      Integer.to_string(trunc(asfloat))
    else
      Float.to_string(asfloat)
    end
  end

  # ------------------------------------------------------------- parser

  @doc """
  Parse JSON text.

  `:error` for anything unreadable - which the caller must tell apart from
  a literal `null` body, since only the first means the store could not
  answer coherently.
  """
  def parse(text) when is_binary(text) and byte_size(text) > 0 do
    # No parse error escapes: a malformed body is a fact about the body,
    # not an exception the caller has to be ready for.
    try do
      {value, rest} = pvalue(skip(text), 0)

      case skip(rest) do
        <<>> -> {:ok, value}
        _more -> :error
      end
    rescue
      _err -> :error
    catch
      :badjson -> :error
    end
  end

  def parse(_other), do: :error

  defp skip(<<ch, rest::binary>>) when ch in [?\s, ?\t, ?\n, ?\r], do: skip(rest)
  defp skip(text), do: text

  defp deeper(depth) do
    if @maxdepth <= depth, do: throw(:badjson)
    depth + 1
  end

  defp pvalue(<<?{, rest::binary>>, depth), do: pobj(skip(rest), deeper(depth), [])
  defp pvalue(<<?[, rest::binary>>, depth), do: parr(skip(rest), deeper(depth), [])
  defp pvalue(<<?", rest::binary>>, _depth), do: pstr(rest, [])
  # Matched whole, never by first letter.
  defp pvalue(<<"true", rest::binary>>, _depth), do: {{:bool, true}, rest}
  defp pvalue(<<"false", rest::binary>>, _depth), do: {{:bool, false}, rest}
  defp pvalue(<<"null", rest::binary>>, _depth), do: {:null, rest}
  defp pvalue(text, _depth), do: pnum(text)

  defp pobj(<<?}, rest::binary>>, _depth, []), do: {{:obj, []}, rest}

  defp pobj(text, depth, acc) do
    {{:str, key}, rest} =
      case skip(text) do
        <<?", body::binary>> -> pstr(body, [])
        _other -> throw(:badjson)
      end

    rest =
      case skip(rest) do
        <<?:, more::binary>> -> more
        _other -> throw(:badjson)
      end

    {value, rest} = pvalue(skip(rest), depth)
    acc = [{key, value} | acc]

    case skip(rest) do
      <<?,, more::binary>> -> pobj(skip(more), depth, acc)
      <<?}, more::binary>> -> {{:obj, Enum.reverse(acc)}, more}
      _other -> throw(:badjson)
    end
  end

  defp parr(<<?], rest::binary>>, _depth, []), do: {{:arr, []}, rest}

  defp parr(text, depth, acc) do
    {value, rest} = pvalue(skip(text), depth)
    acc = [value | acc]

    case skip(rest) do
      <<?,, more::binary>> -> parr(skip(more), depth, acc)
      <<?], more::binary>> -> {{:arr, Enum.reverse(acc)}, more}
      _other -> throw(:badjson)
    end
  end

  defp pstr(<<?", rest::binary>>, acc) do
    {{:str, acc |> Enum.reverse() |> IO.iodata_to_binary()}, rest}
  end

  defp pstr(<<?\\, esc, rest::binary>>, acc) do
    case esc do
      ?" -> pstr(rest, ["\"" | acc])
      ?\\ -> pstr(rest, ["\\" | acc])
      ?/ -> pstr(rest, ["/" | acc])
      ?b -> pstr(rest, ["\b" | acc])
      ?f -> pstr(rest, ["\f" | acc])
      ?n -> pstr(rest, ["\n" | acc])
      ?r -> pstr(rest, ["\r" | acc])
      ?t -> pstr(rest, ["\t" | acc])
      ?u -> punicode(rest, acc)
      _other -> throw(:badjson)
    end
  end

  defp pstr(<<>>, _acc), do: throw(:badjson)

  defp pstr(<<ch::utf8, rest::binary>>, acc), do: pstr(rest, [<<ch::utf8>> | acc])

  # An unpaired byte is still data; a vault answering latin-1 is malformed,
  # not a reason to crash.
  defp pstr(<<ch, rest::binary>>, acc), do: pstr(rest, [<<ch>> | acc])

  # `\uXXXX` carries a UTF-16 code unit. A surrogate PAIR is recombined
  # here, unlike the JVM ports, which append both units to a UTF-16 string
  # and get the same character for free - an Elixir binary is UTF-8 and has
  # no way to hold half a character. A lone surrogate, which no correct
  # encoder emits, becomes the replacement character rather than raising.
  defp punicode(text, acc) do
    {high, rest} = hex4(text)

    cond do
      0xD800 <= high and 0xDBFF >= high ->
        case rest do
          <<?\\, ?u, more::binary>> ->
            {low, after_low} = hex4(more)

            if 0xDC00 <= low and 0xDFFF >= low do
              code = 0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00)
              pstr(after_low, [<<code::utf8>> | acc])
            else
              pstr(after_low, [<<0xFFFD::utf8>>, <<0xFFFD::utf8>> | acc])
            end

          _other ->
            pstr(rest, [<<0xFFFD::utf8>> | acc])
        end

      0xDC00 <= high and 0xDFFF >= high ->
        pstr(rest, [<<0xFFFD::utf8>> | acc])

      true ->
        pstr(rest, [<<high::utf8>> | acc])
    end
  end

  defp hex4(<<digits::binary-size(4), rest::binary>>) do
    case Integer.parse(digits, 16) do
      {value, ""} -> {value, rest}
      _other -> throw(:badjson)
    end
  end

  defp hex4(_short), do: throw(:badjson)

  defp pnum(text) do
    taken = numlen(text, 0)

    if 0 == taken, do: throw(:badjson)

    <<span::binary-size(taken), rest::binary>> = text

    # Float.parse refuses a non-finite result outright, which is what JSON
    # wants: `1e999` is not a number this library can carry, and letting it
    # through as an infinity blows up a token-expiry computation later.
    case Float.parse(span) do
      {value, ""} -> {{:num, value}, rest}
      _other -> throw(:badjson)
    end
  end

  defp numlen(text, at) do
    case text do
      <<_::binary-size(at), ch, _::binary>> when ch in ?0..?9 or ch in [?-, ?+, ?., ?e, ?E] ->
        numlen(text, at + 1)

      _other ->
        at
    end
  end
end
