# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (elixir/lib/voxgig_plugin/env.ex)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
defmodule Voxgig.Plugin.Env do
  @moduledoc """
  Environment overrides (section 9.5) - level 7 of the ladder.

  One prefix, so nothing drifts: `VOXGIG_PLUGIN_*`.

    VOXGIG_PLUGIN_PROFILE            the profile name
    VOXGIG_PLUGIN_<REF>_<PATH>       one option
    VOXGIG_PLUGIN_ACTIVE/INACTIVE    comma-separated refs, INACTIVE wins

  THE ENCODING IS LOSSY, AND THIS SAYS SO RATHER THAN PRETENDING
  OTHERWISE. Ref and path are upper-snake with `$` -> `__` and `.` -> `_`.
  But `_` is legal in a name and in a tag, and the mapping folds case, so
  `retry$fast` and `retry__fast` both encode to `RETRY__FAST`.

  Rather than restrict a grammar the rest of the stack already uses, the
  host DETECTS THE COLLISION: it encodes every ref it holds, and a key two
  refs claim is `plugin_env_ambiguous`, naming both.
  """

  alias Voxgig.Plugin.Json
  alias Voxgig.Plugin.Ref
  alias Voxgig.Plugin.Types

  @prefix "VOXGIG_PLUGIN_"

  @doc "`retry$fast` -> `RETRY__FAST`."
  def encode_ref(ref) do
    ref |> String.replace("$", "__") |> String.replace(".", "_") |> String.upcase()
  end

  def apply_env(input) do
    input = input || %{}
    env = Types.get(input, "env") || %{}
    reserved = Types.get(input, "reserved") || []
    refs = Enum.map(Types.get(input, "refs") || [], &Ref.canon_ref/1)

    # Encode every ref the host holds, and refuse a key that two of them
    # claim. Done up front so the collision is reported even when no
    # environment variable exercises it - a latent ambiguity is still an
    # ambiguity, and finding it at deploy time is the failure this exists
    # to prevent.
    byencoded = Enum.group_by(refs, &encode_ref/1)

    for e <- Types.keys(byencoded), 1 < length(Map.get(byencoded, e)) do
      pair = Enum.sort(Map.get(byencoded, e))

      Types.fail("plugin_env_ambiguous",
                 "refs collide in the environment encoding as #{e}: #{Enum.join(pair, ", ")}",
                 %{"encoded" => e, "refs" => pair})
    end

    # Longest encoded ref first, so `retry$fast` wins over `retry` on
    # `RETRY__FAST_MIN`. Shortest-first would read the tag as a path.
    encoded = byencoded |> Types.keys() |> Types.stable_sort_by(&(-byte_size(&1)))

    start = %{"options" => %{}, "active" => [], "inactive" => []}

    Enum.reduce(Types.keys(env), start, fn key, acc ->
      if String.starts_with?(key, @prefix) do
        onekey(acc, key, String.replace_prefix(key, @prefix, ""), env, encoded, byencoded,
               reserved)
      else
        acc
      end
    end)
  end

  defp onekey(acc, key, "PROFILE", env, _encoded, _byencoded, _reserved) do
    Map.put(acc, "profile", Map.get(env, key))
  end

  defp onekey(acc, key, rest, env, _encoded, _byencoded, reserved)
       when rest in ["ACTIVE", "INACTIVE"] do
    field = if "ACTIVE" == rest, do: "active", else: "inactive"

    added =
      env
      |> Map.get(key)
      |> split()
      |> Enum.map(fn raw ->
        ref = Ref.canon_ref(raw)
        # The reservation covers EVERY input layer (section 9.1).
        # VOXGIG_PLUGIN_INACTIVE=station is easier to set than editing a
        # config file, and INACTIVE has the final word - so guarding
        # documents alone would leave the one lever this mechanism exists
        # to deny wide open.
        checkreserved(ref, reserved)
        ref
      end)

    Map.put(acc, field, Map.get(acc, field) ++ added)
  end

  defp onekey(acc, key, rest, env, encoded, byencoded, reserved) do
    enc = Enum.find(encoded, fn e -> rest == e or String.starts_with?(rest, e <> "_") end)

    cond do
      is_nil(enc) ->
        # not for any ref this host holds
        acc

      true ->
        ref = hd(Map.get(byencoded, enc))
        checkreserved(ref, reserved)

        if rest == enc do
          # a ref with no path sets nothing
          acc
        else
          path =
            rest
            |> String.replace_prefix(enc <> "_", "")
            |> String.downcase()
            |> String.split("_")

          value = parsevalue(Map.get(env, key))
          options = Map.get(acc, "options")
          node = Map.get(options, ref)
          node = if is_map(node), do: node, else: %{}
          Map.put(acc, "options", Map.put(options, ref, setpath(node, path, value)))
        end
    end
  end

  # Write a value at a path, creating maps on the way down. A scalar in the
  # way is REPLACED, which is the same rule every other port applies -
  # spelled recursively here because elixir has no in-place write.
  defp setpath(node, [last], value), do: Map.put(node, last, value)

  defp setpath(node, [step | rest], value) do
    child = Map.get(node, step)
    child = if is_map(child), do: child, else: %{}
    Map.put(node, step, setpath(child, rest, value))
  end

  defp split(value) when is_binary(value) do
    value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&("" == &1))
  end

  defp split(_), do: []

  defp checkreserved(_ref, []), do: :ok

  defp checkreserved(ref, reserved) do
    if Ref.refname(ref) in reserved do
      Types.fail("plugin_ref_reserved", "ref is reserved by the host: #{ref}", %{"ref" => ref})
    end

    :ok
  end

  # Values parse as JSON, FALLING BACK TO STRING - so `8080` is a number,
  # `true` is a boolean, `{"a":1}` is a map, and `hello` is the string it
  # looks like rather than a parse error.
  defp parsevalue(value) when is_binary(value) do
    Json.parse(value)
  rescue
    _ -> value
  end

  defp parsevalue(value), do: value
end
