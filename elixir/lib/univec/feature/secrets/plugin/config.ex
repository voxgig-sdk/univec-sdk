# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (elixir/lib/voxgig_plugin/config.ex)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
defmodule Voxgig.Plugin.Config do
  @moduledoc """
  The declarative document (section 9): normalization, and the ten-level
  precedence ladder.

  TWO FUNCTIONS, AND THE SPLIT BETWEEN THEM IS FORCED.

  `normalize_config` normalizes STRUCTURE and ENTRY KEYS. It does not merge
  options, and cannot: section 9.4 makes merge behaviour a property of the
  definition's option SHAPE, which normalization has never seen. A
  normalizer that flattened the option layers would make `$MERGE: append`
  unimplementable at load time, because the layers it must concatenate
  would already be collapsed.

  `resolve_options` applies the ladder, and it is the only place that knows
  the shape.
  """

  alias Voxgig.Plugin.Ref
  alias Voxgig.Plugin.Types

  @merge_words ~w(replace append)

  def normalize_config(input) do
    input = input || %{}
    doc = Types.get(input, "doc") || %{}
    keys = Types.get(input, "keys") || %{}
    ikey = Types.get(keys, "instance") || "instance"
    dkey = Types.get(keys, "default") || "default"
    reserved = Types.get(input, "reserved") || []
    profile = Types.get(input, "profile")

    # The rename is applied at TWO PLACES AND NO OTHERS: the document root,
    # and every profile.<name> overlay root (section 9.1). A rename applied
    # only at the root would leave `profile.prod.sdk` untranslated and
    # silently drop every environment override the host depends on.
    # Recursing further would be worse: option data is the definition's.
    baseinst = Types.get(doc, ikey)
    basedef = Types.get(doc, dkey) || %{}

    overlay =
      if is_nil(profile) do
        %{}
      else
        Types.get(Types.get(doc, "profile") || %{}, profile)
      end

    overlay = if is_map(overlay), do: overlay, else: %{}
    overinst = Types.get(overlay, ikey)
    overdef = Types.get(overlay, dkey) || %{}

    {basemap, baseorder} = entries(baseinst)
    {overmap, overorder} = entries(overinst)

    for group <- [basemap, overmap, basedef, overdef], r <- Types.keys(group) do
      checkreserved(r, reserved)
    end

    # A PARTIAL ARRAY IS NOT A FILTER (section 9.1). sdkgen learned this
    # the hard way: deriving order from a partial array silently dropped
    # config-activated features. Refs in the base but absent from the
    # overlay still load, in sorted position AFTER the listed ones. A
    # profile may also INTRODUCE a ref the base never declared.
    order = Enum.uniq(overorder ++ baseorder)

    instance =
      order
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {ref, i}, acc ->
        b = Map.get(basemap, ref)
        o = Map.get(overmap, ref)

        # MERGE THE ENTRIES AS AUTHORED, THEN APPLY DEFAULTS TO THE RESULT
        # (section 9.3). A safety rule, not a tidiness one: if the overlay
        # had its defaults filled in before merging it would carry a
        # synthesized active:true and overwrite a base's false - silently
        # re-enabling a deliberately disabled integration in production.
        active = pick(o, "active", pick(b, "active", true))
        start = pick(o, "start", pick(b, "start", "eager"))
        block = pick(o, "order", pick(b, "order", nil))

        # Option layers, levels 3-6, IN LADDER ORDER. Never merged here.
        nm = Ref.refname(ref)

        layers =
          [Types.get(basedef, nm), b, Types.get(overdef, nm), o]
          |> Enum.filter(&Types.has(&1, "options"))
          |> Enum.map(&Map.get(&1, "options"))

        ent = %{"pos" => i, "active" => active, "start" => start,
                "optionlayers" => layers}

        ent = if is_nil(block), do: ent, else: Map.put(ent, "order", block)
        Map.put(acc, ref, ent)
      end)

    # `default` DECLARES NOTHING (section 9.3). It is a base for every
    # instance of that definition; it does not create one, and an entry for
    # a name with no instances is inert rather than an error - which is
    # what makes a shared library of defaults shippable.
    defout = Map.merge(basedef, overdef)

    %{"instance" => instance, "order" => order, "default" => defout}
  end

  # Both document forms reduce to {ref -> entry} plus the order the form
  # implies: array POSITION for the array form, sorted refs for the map
  # form.
  defp entries(nil), do: {%{}, []}

  defp entries(src) when is_list(src) do
    Enum.reduce(src, {%{}, []}, fn item, {map, order} ->
      ref = Ref.canon_ref(Types.get(item, "ref"))
      {Map.put(map, ref, item), order ++ [ref]}
    end)
  end

  defp entries(src) when is_map(src) do
    map =
      Enum.reduce(Types.keys(src), %{}, fn key, acc ->
        Map.put(acc, Ref.canon_ref(key), Map.get(src, key))
      end)

    # Byte-wise, NOT locale-aware and NOT case-folded. All-lowercase refs
    # sort identically under all three, so only mixed input discriminates:
    # '@' is 0x40, uppercase 0x41-0x5A, lowercase 0x61-0x7A. Elixir's `<`
    # on binaries is exactly that.
    {map, Types.keys(map)}
  end

  # Section 9.1: reservation is all-or-nothing per NAME, so the tagged
  # forms go too. A configuration surface that can disable the thing
  # reading it is not a surface, it is a trap.
  defp checkreserved(_ref, []), do: :ok

  defp checkreserved(ref, reserved) do
    if Ref.refname(ref) in reserved do
      Types.fail("plugin_ref_reserved", "ref is reserved by the host: #{ref}", %{"ref" => ref})
    end

    :ok
  end

  # PRESENCE decides, not truthiness and not nil. A JSON `null` is a
  # present value in JavaScript (`undefined !== null`), so it must be one
  # here - and a map that HOLDS nil is what lets elixir say so without a
  # sentinel.
  defp pick(src, key, dflt) do
    if Types.has(src, key), do: Map.get(src, key), else: dflt
  end

  # ------------------------------------------------------------------
  # resolve_options - section 9.3's ten levels, and 9.4's directives
  # ------------------------------------------------------------------

  def resolve_options(input) do
    shape = Types.get(input, "shape") || %{}
    check_shape(shape)

    ref = Ref.canon_ref(Types.get(input, "ref"))
    name = Ref.refname(ref)
    doc = Types.get(input, "doc") || %{}
    profile = Types.get(input, "profile")

    overlay =
      if is_nil(profile) do
        %{}
      else
        Types.get(Types.get(doc, "profile") || %{}, profile)
      end

    overlay = if is_map(overlay), do: overlay, else: %{}

    # ONE ordered merge, lowest to highest. Levels 3-6 are not two
    # namespaces collapsed separately and composed afterwards: that inverts
    # the rule that PROFILE SPECIFICITY OUTRANKS DEFINITION SPECIFICITY, so
    # a prod per-definition default would lose to a base instance value.
    layers = [
      defaultsof(shape),
      Types.get(input, "hostdefaults"),
      optsof(Types.get(doc, "default"), name),
      optsof(Types.get(doc, "instance"), ref),
      optsof(Types.get(overlay, "default"), name),
      optsof(Types.get(overlay, "instance"), ref),
      Types.get(input, "env"),
      Types.get(input, "hostoptions"),
      Types.get(input, "loadoptions"),
      Types.get(input, "patch")
    ]

    Enum.reduce(layers, %{}, fn layer, acc ->
      if is_nil(layer), do: acc, else: mergeone(acc, layer, shape)
    end)
  end

  # The shape's non-directive values are the level-1 defaults.
  defp defaultsof(shape) do
    shape
    |> Types.keys()
    |> Enum.reject(&Types.has(Map.get(shape, &1), "$MERGE"))
    |> Enum.reduce(%{}, fn k, acc -> Map.put(acc, k, Map.get(shape, k)) end)
  end

  defp optsof(nil, _key), do: nil

  defp optsof(src, key) when is_list(src) do
    # The array form is equivalent to the map form (section 9.1).
    case Enum.find(src, fn item -> Ref.canon_ref(Types.get(item, "ref")) == key end) do
      nil -> nil
      item -> Types.get(item, "options")
    end
  end

  defp optsof(src, key) when is_map(src) do
    case Enum.find(Types.keys(src), fn k -> Ref.canon_ref(k) == key end) do
      nil ->
        nil

      k ->
        entry = Map.get(src, k)
        if is_map(entry), do: Types.get(entry, "options"), else: nil
    end
  end

  # Merge ONE layer onto the accumulator, honouring the shape's directives.
  # The directive holds at EVERY precedence level, not only between
  # document levels - section 9.4 makes it a property of the shape, which
  # does not know which layer a value arrived from.
  defp mergeone(base, over, _shape) when not is_map(base) or not is_map(over), do: over

  defp mergeone(base, over, shape) do
    Enum.reduce(Types.keys(over), base, fn k, acc ->
      o = Map.get(over, k)
      directive = Types.get(Types.get(shape, k) || %{}, "$MERGE")
      b = Map.get(acc, k)

      merged =
        cond do
          "replace" == directive ->
            o

          "append" == directive ->
            bl = if is_list(b), do: b, else: []
            ol = if is_list(o), do: o, else: [o]
            bl ++ ol

          Types.has(directive, "deep") ->
            deepto(b, o, Map.get(directive, "deep"))

          # Library default: deep for maps, REPLACE for lists. struct.merge
          # is element-wise by index, which for option maps is nearly
          # always wrong - ["a"] over ["x","y","z"] yielding ["a","y","z"]
          # is the defect station hit on secrets.providers.
          is_map(b) and is_map(o) ->
            mergeone(b, o, nil)

          true ->
            o
        end

      Map.put(acc, k, merged)
    end)
  end

  # Merge N levels below this key, replace below that.
  defp deepto(_base, over, n) when n <= 0, do: over
  defp deepto(base, over, _n) when not is_map(base) or not is_map(over), do: over

  defp deepto(base, over, n) do
    Enum.reduce(Types.keys(over), base, fn k, acc ->
      Map.put(acc, k, deepto(Map.get(acc, k), Map.get(over, k), n - 1))
    end)
  end

  @doc """
  Section 9.4: N is an integer of at least 1, and everything else is an
  error.

  `{"deep": 0}` is rejected DESPITE having an obvious reading, because
  "replace at this key" already has a spelling and two spellings for one
  behaviour is the defect class this repo exists to avoid.
  """
  def check_shape(shape) when is_map(shape) do
    for k <- Types.keys(shape), Types.has(Map.get(shape, k), "$MERGE") do
      directive = Map.get(Map.get(shape, k), "$MERGE")

      cond do
        is_binary(directive) and directive in @merge_words ->
          :ok

        is_binary(directive) ->
          Types.fail("plugin_shape_invalid",
                     "invalid $MERGE directive at #{k}: #{directive}", %{"key" => k})

        Types.has(directive, "deep") ->
          n = Map.get(directive, "deep")

          # A JSON NUMBER, and an integer of at least 1. `is_integer`
          # excludes `true` (which is not an integer in elixir) and `"2"`,
          # so the type test the dynamic ports need is the guard itself.
          if not (is_integer(n) and n >= 1) do
            Types.fail("plugin_shape_invalid",
                       "invalid $MERGE deep at #{k}: #{Types.encode(n)}", %{"key" => k})
          end

        true ->
          Types.fail("plugin_shape_invalid",
                     "invalid $MERGE directive at #{k}: #{Types.encode(directive)}",
                     %{"key" => k})
      end
    end

    :ok
  end

  def check_shape(_), do: :ok
end
