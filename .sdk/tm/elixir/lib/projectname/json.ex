# Univec SDK JSON parser
#
# A tiny dependency-free JSON reader that parses directly into the vendored
# struct's heap nodes (built with jm/jt), the representation the SDK
# operates on. Mirrors the parser shipped with the struct test runner.

defmodule Univec.Json do
  alias Voxgig.Struct, as: S

  def parse(str) do
    {v, _rest} = parse_value(str)
    v
  end

  defp skip_ws(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r], do: skip_ws(rest)
  defp skip_ws(s), do: s

  defp parse_value(s) do
    s = skip_ws(s)

    case s do
      "{" <> rest -> parse_object(rest, [])
      "[" <> rest -> parse_array(rest, [])
      "\"" <> rest -> parse_string_raw(rest, [])
      "true" <> rest -> {true, rest}
      "false" <> rest -> {false, rest}
      "null" <> rest -> {nil, rest}
      _ -> parse_number(s)
    end
  end

  defp parse_object(s, acc) do
    s = skip_ws(s)

    case s do
      "}" <> rest ->
        pairs = acc |> Enum.reverse() |> Enum.flat_map(fn {k, v} -> [k, v] end)
        {S.jm(pairs), rest}

      _ ->
        "\"" <> s1 = s
        {key, s2} = parse_string_raw(s1, [])
        s3 = skip_ws(s2)
        ":" <> s4 = s3
        {val, s5} = parse_value(s4)
        s6 = skip_ws(s5)

        case s6 do
          "," <> r -> parse_object(r, [{key, val} | acc])
          "}" <> r -> parse_object("}" <> r, [{key, val} | acc])
        end
    end
  end

  defp parse_array(s, acc) do
    s = skip_ws(s)

    case s do
      "]" <> rest ->
        {S.jt(Enum.reverse(acc)), rest}

      _ ->
        {val, s1} = parse_value(s)
        s2 = skip_ws(s1)

        case s2 do
          "," <> r -> parse_array(r, [val | acc])
          "]" <> r -> parse_array("]" <> r, [val | acc])
        end
    end
  end

  defp parse_string_raw("\"" <> rest, acc), do: {IO.iodata_to_binary(Enum.reverse(acc)), rest}

  defp parse_string_raw("\\" <> <<c, rest::binary>>, acc) do
    case c do
      ?" -> parse_string_raw(rest, ["\"" | acc])
      ?\\ -> parse_string_raw(rest, ["\\" | acc])
      ?/ -> parse_string_raw(rest, ["/" | acc])
      ?n -> parse_string_raw(rest, ["\n" | acc])
      ?r -> parse_string_raw(rest, ["\r" | acc])
      ?t -> parse_string_raw(rest, ["\t" | acc])
      ?b -> parse_string_raw(rest, [<<8>> | acc])
      ?f -> parse_string_raw(rest, [<<12>> | acc])
      ?u ->
        <<hex::binary-size(4), rest2::binary>> = rest
        code = String.to_integer(hex, 16)
        parse_string_raw(rest2, [<<code::utf8>> | acc])
    end
  end

  defp parse_string_raw(<<c::utf8, rest::binary>>, acc),
    do: parse_string_raw(rest, [<<c::utf8>> | acc])

  defp parse_number(s) do
    {numstr, rest} = take_number(s, [])
    n = IO.iodata_to_binary(Enum.reverse(numstr))

    val =
      if String.contains?(n, ".") or String.contains?(n, "e") or String.contains?(n, "E") do
        {f, ""} = Float.parse(n)
        f
      else
        String.to_integer(n)
      end

    {val, rest}
  end

  defp take_number(<<c, rest::binary>>, acc)
       when c in ?0..?9 or c in [?-, ?+, ?., ?e, ?E],
       do: take_number(rest, [<<c>> | acc])

  defp take_number(s, acc), do: {acc, s}
end
