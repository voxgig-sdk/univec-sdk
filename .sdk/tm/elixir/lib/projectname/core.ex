# Univec SDK core runtime objects.
#
# Control / Spec / Result / Response / Operation are all struct map nodes
# (reference-stable, ETS-backed) built with small constructor modules so
# the pipeline and feature hooks can read and mutate their fields uniformly
# via struct getprop/setprop.

defmodule Univec.Control do
  alias Voxgig.Struct, as: S

  # opts is a struct map node or nil.
  def new(opts \\ nil) do
    m = if S.ismap(opts), do: opts, else: S.jm([])

    S.jm([
      "throw_err", S.getprop(m, "throw_err"),
      "err", nil,
      "explain", S.getprop(m, "explain"),
      "actor", S.getprop(m, "actor"),
      "paging", S.getprop(m, "paging")
    ])
  end
end

defmodule Univec.Spec do
  alias Voxgig.Struct, as: S

  def new(specmap \\ nil) do
    m = if S.ismap(specmap), do: specmap, else: S.jm([])
    d = fn k, dflt -> v = S.getprop(m, k); if(v == nil, do: dflt, else: v) end

    S.jm([
      "parts", d.("parts", S.jt([])),
      "headers", d.("headers", S.jm([])),
      "alias", d.("alias", S.jm([])),
      "base", d.("base", ""),
      "prefix", d.("prefix", ""),
      "suffix", d.("suffix", ""),
      "params", d.("params", S.jm([])),
      "query", d.("query", S.jm([])),
      "step", d.("step", ""),
      "method", d.("method", "GET"),
      "body", S.getprop(m, "body"),
      "url", d.("url", ""),
      "path", d.("path", "")
    ])
  end
end

defmodule Univec.Result do
  alias Voxgig.Struct, as: S

  def new(resmap \\ nil) do
    m = if S.ismap(resmap), do: resmap, else: S.jm([])

    status =
      case S.getprop(m, "status") do
        s when is_integer(s) -> s
        s when is_float(s) -> trunc(s)
        _ -> -1
      end

    st = S.getprop(m, "statusText")
    headers = S.getprop(m, "headers")
    rm = S.getprop(m, "resmatch")

    S.jm([
      "ok", S.getprop(m, "ok") == true,
      "status", status,
      "status_text", if(is_binary(st), do: st, else: ""),
      "headers", if(S.ismap(headers), do: headers, else: S.jm([])),
      "body", S.getprop(m, "body"),
      "err", S.getprop(m, "err"),
      "resdata", S.getprop(m, "resdata"),
      "resmatch", if(S.ismap(rm), do: rm, else: nil)
    ])
  end
end

defmodule Univec.Response do
  alias Voxgig.Struct, as: S

  def new(resmap \\ nil) do
    m = if S.ismap(resmap), do: resmap, else: S.jm([])

    status =
      case S.getprop(m, "status") do
        s when is_integer(s) -> s
        s when is_float(s) -> trunc(s)
        _ -> -1
      end

    st = S.getprop(m, "statusText")
    jf = S.getprop(m, "json")

    S.jm([
      "status", status,
      "status_text", if(is_binary(st), do: st, else: ""),
      "headers", S.getprop(m, "headers"),
      "json_func", if(S.isfunc(jf), do: jf, else: nil),
      "body", S.getprop(m, "body"),
      "err", S.getprop(m, "err")
    ])
  end
end

defmodule Univec.Operation do
  alias Voxgig.Struct, as: S

  defp strval(v, d), do: if(is_binary(v) and v != "", do: v, else: d)

  def new(opmap \\ nil) do
    m = if S.ismap(opmap), do: opmap, else: S.jm([])
    raw = S.getprop(m, "points")
    al = S.getprop(m, "alias")

    S.jm([
      "entity", strval(S.getprop(m, "entity"), "_"),
      "name", strval(S.getprop(m, "name"), "_"),
      "input", strval(S.getprop(m, "input"), "_"),
      "points", if(S.islist(raw), do: raw, else: S.jt([])),
      "alias", if(S.ismap(al), do: al, else: nil)
    ])
  end
end
