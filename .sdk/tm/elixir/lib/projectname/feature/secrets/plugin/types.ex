# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (elixir/lib/voxgig_plugin/types.ex)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
defmodule Voxgig.Plugin.Types do
  @moduledoc """
  Shared types and the value helpers every module reads data through.

  Deliberately small: the design's section 19 budget says the library owns
  naming, configuration, lifecycle, ordering, binding and teardown, and
  nothing else.

  ELIXIR IS THE FIRST PORT THAT NEEDS NO TRICKS FOR THE VALUE MODEL, and
  it is worth saying which tricks it does without:

    * `%{}` and `[]` are DIFFERENT TYPES, so the empty-map-versus-empty-list
      distinction php cannot draw and lua needs tagged tables for is free
      here.
    * A map holds `nil`, so `Map.has_key?` separates ABSENT from
      present-and-null with no sentinel - perl and lua both carry one.
    * `1 == 1.0` is true and `true == 1`, `"1" == 1` are both false, which
      is exactly JSON's one number type plus JSON's type-strict equality.
      php, perl and lua each need a guard for that; ruby, rust, java and
      this port do not.

  What it does NOT give free is mutation, and `Voxgig.Plugin.Host` says
  what that cost.
  """

  @doc "Section 5.1's seven statuses, and no more."
  def statuses, do: ~w(declared loaded pending live failed loading closing)

  @doc """
  Section 12's detail fields, IN THIS FIXED ORDER.

  The order is part of the contract, not a formatting preference. An
  earlier draft named six fields while other sections promised diagnostics
  that had nowhere to go, which would have left each port inventing its own
  order and breaking message parity.
  """
  def detail_order do
    ~w(host ref name tag point key capability range version match
       candidates cycle holders refs path cause)
  end

  @doc "The value at a key, or nil. Absence and null read the same here."
  def get(map, key) when is_map(map), do: Map.get(map, key)
  def get(_, _), do: nil

  @doc "PRESENCE, which is what distinguishes an authored null from absence."
  def has(map, key) when is_map(map), do: Map.has_key?(map, key)
  def has(_, _), do: false

  def at(list, index) when is_list(list), do: Enum.at(list, index)
  def at(_, _), do: nil

  @doc "The keys of a map, SORTED - every walk of a map goes through here."
  def keys(map) when is_map(map), do: map |> Map.keys() |> Enum.sort()
  def keys(_), do: []

  @doc """
  Ruby's truthiness, which is not elixir's: present, and not `false`. `0`
  and `""` are values the corpus distinguishes from absence, and elixir
  already agrees about those two - only `nil` and `false` are falsy.
  """
  def truthy(value), do: not (is_nil(value) or false == value)

  @doc """
  An INTEGER, and only when the value is one. Section 7's band is an
  integer the document wrote as one; `true` and `"2"` are not bands.
  """
  def asint(value) when is_integer(value), do: value
  def asint(value) when is_float(value) do
    if value == Float.floor(value), do: trunc(value), else: nil
  end
  def asint(_), do: nil

  @doc """
  A STABLE sort by a key function.

  Stability is load-bearing, not tidiness: the canonical's comparators fall
  through to a `pos` or ref tie-break that javascript's stable sort then
  resolves by POSITION, and a port that shuffled equal keys would order a
  teardown differently between two runs of the same process. Replacing this
  with an unstable sort fails `order/order/seqtie`.

  `Enum.sort_by/2` is already that sort. Its documented promise is
  conditional - `Enum.sort/2` is "stable as long as the given function
  returns true for equal terms" - and the `<=` comparator `sort_by/2`
  builds from a key function is exactly one that does. THE NAME IS WHAT
  THIS FUNCTION IS FOR: every sort in the port goes through one place that
  says stability is required, so the next reader does not have to re-derive
  that conditional from the docs.
  """
  def stable_sort_by(list, keyfun), do: Enum.sort_by(list, keyfun)

  @doc """
  JSON equality: same type, then same value.

  `==` is exactly right here: it reads `1 == 1.0` as true (JSON has one
  number type) and `true == 1`, `"1" == 1` as false (JSON is type-strict).
  Map and list comparison is structural and key order does not matter,
  which is what the corpus asserts.
  """
  def same(a, b), do: a == b

  @doc """
  `plugin/<code>: <text> [<key>=<value> ...]`

  Values render as COMPACT JSON, so a value containing a space or a bracket
  cannot break the parse, and a list renders as a JSON array. The bracket
  is absent entirely when no field applies.
  """
  def formaterror(code, text, details) do
    parts =
      detail_order()
      |> Enum.filter(&has(details, &1))
      |> Enum.map(fn k -> "#{k}=#{encode(Map.get(details, k))}" end)

    tail = if [] == parts, do: "", else: " [" <> Enum.join(parts, " ") <> "]"
    "plugin/#{code}: #{text}#{tail}"
  end

  @doc "Throw a section 12 error. One spelling, so every raise site reads the same."
  def fail(code, text, details \\ %{}) do
    raise Voxgig.Plugin.Error,
      code: code,
      text: text,
      details: details,
      message: formaterror(code, text, details)
  end

  @doc """
  The section 12 code of an error, or "" for one this library did not
  raise. The corpus compares by code, so the driver needs one place that
  knows how to read it.
  """
  def codeof(%Voxgig.Plugin.Error{code: code}), do: code
  def codeof(_), do: ""

  def message(%Voxgig.Plugin.Error{message: message}), do: message
  def message(error) when is_exception(error), do: Exception.message(error)
  def message(other), do: inspect(other)

  @doc """
  Compact JSON, map keys in sorted order.

  Written here rather than in `Json` so that `formaterror` - which every
  module reaches - does not pull the parser in behind it.
  """
  def encode(nil), do: "null"
  def encode(true), do: "true"
  def encode(false), do: "false"

  def encode(value) when is_integer(value), do: Integer.to_string(value)

  def encode(value) when is_float(value) do
    # An integral float prints without a fractional part, so a `pos` of 3
    # renders as `3` and not `3.0` - JSON has one number type and the
    # corpus writes them as it means them.
    if value == Float.floor(value) and abs(value) < 1.0e15 do
      Integer.to_string(trunc(value))
    else
      Float.to_string(value)
    end
  end

  def encode(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    "\"" <> escaped <> "\""
  end

  def encode(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &encode/1) <> "]"
  end

  def encode(value) when is_map(value) and not is_struct(value) do
    "{" <> Enum.map_join(keys(value), ",", fn k -> encode(k) <> ":" <> encode(Map.get(value, k)) end) <> "}"
  end

  # A host object published through `exports` (section 11) - the library
  # never inspects one and nothing in the corpus compares one.
  def encode(_), do: "\"(opaque)\""
end
