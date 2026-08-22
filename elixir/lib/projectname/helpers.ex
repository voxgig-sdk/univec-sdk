# Univec SDK helpers
#
# Shared value helpers built on the vendored struct value type. Every SDK
# runtime object (context, spec, result, response, control, operation,
# utility, features, the client itself) is a reference-stable struct map
# node ({:vmap, id}, ETS-backed) so that a feature hook mutating the node
# is observed by every later pipeline stage that holds the same reference
# — the immutable-Elixir way to honour the shared-mutable hook contract.

defmodule Univec.Helpers do
  alias Voxgig.Struct, as: S

  # Return v when it is a struct map node, else nil (mirrors py to_map).
  def to_map(v), do: if(S.ismap(v), do: v, else: nil)

  def to_int(v) when is_integer(v), do: v
  def to_int(v) when is_float(v), do: trunc(v)
  def to_int(_), do: -1

  # Read a key from a struct map node, nil when the map/key is absent.
  def get_ctx_prop(m, key), do: if(S.ismap(m), do: S.getprop(m, key), else: nil)

  # Insertion-ordered {k, v} pairs of a struct map node as a plain Elixir
  # list (struct keysof sorts; several pipeline steps need source order).
  def entries(node) do
    it = S.items(node)
    n = S.size(it)
    if n == 0 do
      []
    else
      Enum.map(0..(n - 1), fn i ->
        p = S.getelem(it, i)
        {S.getelem(p, 0), S.getelem(p, 1)}
      end)
    end
  end

  # Deep-convert a native Elixir term (maps/lists/scalars, incl. function
  # values) into struct nodes. Used by generated config and option specs.
  def deep(v) do
    cond do
      is_map(v) and not is_struct(v) ->
        S.jm(Enum.flat_map(v, fn {k, val} -> [to_string(k), deep(val)] end))

      is_list(v) ->
        S.jt(Enum.map(v, &deep/1))

      true ->
        v
    end
  end

  # Truthy in the JS/py sense: nil and false are falsey, everything else
  # (including 0 and "") is truthy — matches the donors' `or`/`if` idioms.
  def truthy(nil), do: false
  def truthy(false), do: false
  def truthy(_), do: true

  # First truthy value (JS `a || b`).
  def or_(a, b), do: if(truthy(a), do: a, else: b)

  def is_error(v), do: is_exception(v)

  def str_or(v, d) when is_binary(v), do: if(v == "", do: d, else: v)
  def str_or(_, d), do: d
end
