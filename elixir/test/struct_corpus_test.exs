# Univec SDK struct corpus test
#
# The struct corpus (.sdk/test/test.json -> "struct") drives the LIVE SDK's
# vendored struct utilities through the VENDORED @voxgig/omni engine, via the
# resolver in test/support/omni.ex. The hand-written engine this suite used to
# call (test/support/struct_corpus.ex - fixJson / eqv / doMatch / runSet /
# runSingle, transcribed by hand) is retired: omni resolves arguments, applies
# the null rules and enforces out/err/match, so the subjects below are the
# whole of what this port contributes. See docs/design/vendor-tag-rollout.md.
#
# Every group goes through `runset`/`runsetflags`, so a corpus entry that
# changes or is added is executed here without anything being edited. omni
# RAISES on the first failing entry rather than tallying, so the suite also
# counts the subject invocations and asserts a floor: a renamed section, or a
# fixture that compiled to an empty `set`, would otherwise pass silently -
# which is the one failure mode a shared oracle exists to prevent.

defmodule Univec.StructCorpusTest do
  use ExUnit.Case

  alias Voxgig.Struct, as: S
  alias Univec.Omni, as: O

  # Groups this port cannot express, dropped ENTRY BY ENTRY rather than by
  # marking a whole group pending and losing the rest of it.
  #
  # Elixir has ONE `nil` where the canonical port has `undefined` and JSON
  # `null` (the vendored struct says so in its own header), so a subject that
  # returns NOTHING and one that returns JSON null are the same value here.
  # Under `{null: true}` the runner normalises both to NULLMARK and the
  # distinction never arises; the `{null: false}` groups are where it bites,
  # and the corpus is lopsided - reading a bare nil as ABSENT (test/support/
  # omni.ex decision 5) costs the four entries below, reading it as null costs
  # 43. Each drop is GUARDED on the entry's exact JSON: corpus indexes are
  # positional, so a corpus that gains or reorders an entry fails loudly here
  # instead of quietly skipping a different one.
  @drops %{
    {"minor", "clone"} => [{5, ~s({"in":null,"out":null})}],
    {"minor", "getprop"} => [
      {50, ~s({"in":{"alt":null,"key":"x","val":{}},"out":null})},
      {51, ~s({"in":{"alt":null,"key":null,"val":{}},"out":null})}
    ],
    {"validate", "basic"} => [{13, ~s({"in":{"data":null,"spec":"`$NULL`"},"out":null})}]
  }

  setup_all do
    testfile = Path.join(File.cwd!(), "../.sdk/test/test.json")
    runner = O.make_runner(testfile, Univec.test())
    {:ok, run: runner.("struct")}
  end

  # --- corpus plumbing -----------------------------------------------------

  defp group(spec, name, sub) do
    section = Map.get(spec, name)

    assert is_map(section),
           "corpus section 'struct.#{name}' missing - check the name against .sdk/test/struct/"

    node = Map.get(section, sub)

    assert is_map(node) and is_list(Map.get(node, "set")),
           "corpus group 'struct.#{name}.#{sub}' has no set list"

    assert [] != Map.get(node, "set"),
           "corpus group 'struct.#{name}.#{sub}' is EMPTY - zero cases would run"

    drop(node, Map.get(@drops, {name, sub}, []))
  end

  defp drop(node, []), do: node

  defp drop(node, drops) do
    set = Map.get(node, "set")

    Enum.each(drops, fn {index, want} ->
      got = O.stringify(Enum.at(set, index))

      assert got == want,
             "corpus drop guard: entry #{index} is #{got}, expected #{want} - " <>
               "the corpus changed, so re-measure the drop before moving it"
    end)

    indexes = MapSet.new(Enum.map(drops, fn {index, _} -> index end))

    kept =
      set
      |> Enum.with_index()
      |> Enum.reject(fn {_entry, index} -> MapSet.member?(indexes, index) end)
      |> Enum.map(fn {entry, _index} -> entry end)

    Map.put(node, "set", kept)
  end

  # A single-node corpus group (`{in, out}` with no `set`) run as a one-entry
  # set, so it goes through the SAME engine as everything else rather than a
  # bespoke comparison.
  defp single(spec, name, sub) do
    node = Map.get(Map.get(spec, name, %{}), sub)
    assert is_map(node) and Map.has_key?(node, "in"), "corpus group 'struct.#{name}.#{sub}' missing"
    %{"set" => [node]}
  end

  # --- subject helpers -----------------------------------------------------

  # The corpus subjects take omni's resolved ARGUMENT LIST; most want its
  # single element, and an entry with no argument at all arrives as `[]`
  # (omni.ex decision 4), which the no-arg subjects below branch on.
  defp arg1(fun), do: fn args -> fun.(if(args == [], do: nil, else: hd(args))) end

  defp vget(vin, key), do: if(S.ismap(vin), do: S.getprop(vin, key), else: nil)
  defp vhas(vin, key), do: S.ismap(vin) and Enum.member?(S.keysof(vin), key)

  defp velems(val) do
    if S.islist(val) do
      n = S.size(val)
      if n == 0, do: [], else: Enum.map(0..(n - 1), fn i -> S.getelem(val, i) end)
    else
      []
    end
  end

  defp jss(val) do
    cond do
      val == nil -> "null"
      is_binary(val) -> val
      true -> S.stringify(val)
    end
  end

  defp joinpath(path), do: velems(path) |> Enum.map(&jss/1) |> Enum.join(".")

  defp grow_list(node, index) do
    if S.size(node) <= index do
      S.setprop(node, S.size(node), nil)
      grow_list(node, index)
    end
  end

  defp walk_copy_subject(vin) do
    cur = S.jt([nil])

    walkcopy = fn key, val, _parent, path ->
      if key == nil do
        inner =
          S.jt([
            cond do
              S.ismap(val) -> S.jm([])
              S.islist(val) -> S.jt([])
              true -> val
            end
          ])

        S.setprop(cur, 0, inner)
      else
        i = S.size(path)

        nv =
          if S.isnode(val) do
            c = S.getelem(cur, 0)
            grow_list(c, i)
            nvx = if S.ismap(val), do: S.jm([]), else: S.jt([])
            S.setprop(c, i, nvx)
            nvx
          else
            val
          end

        S.setprop(S.getelem(S.getelem(cur, 0), i - 1), key, nv)
      end

      val
    end

    S.walk(vin, before: walkcopy)
    S.getelem(S.getelem(cur, 0), 0)
  end

  defp walk_depth_subject(vin) do
    state = S.jm(["top", nil, "cur", nil])

    copy = fn key, val, _parent, _path ->
      if key == nil or S.isnode(val) do
        child = if S.islist(val), do: S.jt([]), else: S.jm([])

        if key == nil do
          S.setprop(state, "top", child)
          S.setprop(state, "cur", child)
        else
          S.setprop(S.getprop(state, "cur"), key, child)
          S.setprop(state, "cur", child)
        end
      else
        S.setprop(S.getprop(state, "cur"), key, val)
      end

      val
    end

    S.walk(vget(vin, "src"), before: copy, maxdepth: vget(vin, "maxdepth"))
    S.getprop(state, "top")
  end

  defp walk_log_subject(vin) do
    logline = fn key, val, parent, path ->
      "k=" <>
        (if key == nil, do: S.stringify(), else: S.stringify(key)) <>
        ", v=" <>
        S.stringify(val) <>
        ", p=" <>
        (if parent == nil, do: S.stringify(), else: S.stringify(parent)) <>
        ", t=" <> S.pathify(path)
    end

    collect = fn log ->
      fn key, val, parent, path ->
        S.setprop(log, S.size(log), logline.(key, val, parent, path))
        val
      end
    end

    after_log = S.jt([])
    S.walk(S.clone(vin), after: collect.(after_log))

    before_log = S.jt([])
    S.walk(S.clone(vin), before: collect.(before_log))

    both_log = S.jt([])
    S.walk(S.clone(vin), before: collect.(both_log), after: collect.(both_log))

    S.jm(["after", after_log, "before", before_log, "both", both_log])
  end

  # --- the corpus ----------------------------------------------------------

  test "the struct corpus runs through the vendored omni engine", %{run: run} do
    O.reset_cases()

    spec = run.spec
    runset = run.runset
    runsetflags = run.runsetflags

    nonull = fn name, sub, subject ->
      runsetflags.(group(spec, name, sub), %{null: false, name: "struct.#{name}.#{sub}"}, subject)
    end

    withnull = fn name, sub, subject ->
      runsetflags.(group(spec, name, sub), %{name: "struct.#{name}.#{sub}"}, subject)
    end

    # --- minor ---

    withnull.("minor", "isnode", arg1(fn v -> S.isnode(v) end))
    withnull.("minor", "ismap", arg1(fn v -> S.ismap(v) end))
    withnull.("minor", "islist", arg1(fn v -> S.islist(v) end))
    nonull.("minor", "iskey", arg1(fn v -> S.iskey(v) end))
    nonull.("minor", "strkey", arg1(fn v -> S.strkey(v) end))
    nonull.("minor", "isempty", arg1(fn v -> S.isempty(v) end))
    withnull.("minor", "isfunc", arg1(fn v -> S.isfunc(v) end))
    nonull.("minor", "clone", arg1(fn v -> S.clone(v) end))
    withnull.("minor", "escre", arg1(fn v -> S.escre(v) end))
    withnull.("minor", "escurl", arg1(fn v -> S.escurl(v) end))

    nonull.(
      "minor",
      "stringify",
      arg1(fn vin ->
        if vhas(vin, "val"),
          do: S.stringify(vget(vin, "val"), vget(vin, "max")),
          else: S.stringify()
      end)
    )

    nonull.("minor", "jsonify", arg1(fn vin -> S.jsonify(vget(vin, "val"), vget(vin, "flags")) end))

    nonull.(
      "minor",
      "getelem",
      arg1(fn vin ->
        alt = vget(vin, "alt")

        if alt == nil,
          do: S.getelem(vget(vin, "val"), vget(vin, "key")),
          else: S.getelem(vget(vin, "val"), vget(vin, "key"), alt)
      end)
    )

    withnull.("minor", "delprop", arg1(fn vin -> S.delprop(vget(vin, "parent"), vget(vin, "key")) end))
    nonull.("minor", "size", arg1(fn v -> S.size(v) end))

    nonull.(
      "minor",
      "slice",
      arg1(fn vin -> S.slice(vget(vin, "val"), vget(vin, "start"), vget(vin, "end")) end)
    )

    nonull.(
      "minor",
      "pad",
      arg1(fn vin -> S.pad(vget(vin, "val"), vget(vin, "pad"), vget(vin, "char")) end)
    )

    nonull.(
      "minor",
      "pathify",
      arg1(fn vin ->
        if vhas(vin, "path"),
          do: S.pathify(vget(vin, "path"), vget(vin, "from")),
          else: S.pathify(S.noarg(), vget(vin, "from"))
      end)
    )

    withnull.("minor", "items", arg1(fn v -> S.items(v) end))

    nonull.(
      "minor",
      "getprop",
      arg1(fn vin ->
        alt = vget(vin, "alt")

        if alt == nil,
          do: S.getprop(vget(vin, "val"), vget(vin, "key")),
          else: S.getprop(vget(vin, "val"), vget(vin, "key"), alt)
      end)
    )

    withnull.(
      "minor",
      "setprop",
      arg1(fn vin -> S.setprop(vget(vin, "parent"), vget(vin, "key"), vget(vin, "val")) end)
    )

    nonull.("minor", "haskey", arg1(fn vin -> S.haskey(vget(vin, "src"), vget(vin, "key")) end))
    withnull.("minor", "keysof", arg1(fn v -> S.keysof(v) |> S.jt() end))

    nonull.(
      "minor",
      "join",
      arg1(fn vin -> S.join(vget(vin, "val"), vget(vin, "sep"), vget(vin, "url")) end)
    )

    nonull.("minor", "typify", fn args ->
      S.typify(if(args == [], do: S.noarg(), else: hd(args)))
    end)

    nonull.(
      "minor",
      "setpath",
      arg1(fn vin -> S.setpath(vget(vin, "store"), vget(vin, "path"), vget(vin, "val")) end)
    )

    withnull.(
      "minor",
      "filter",
      arg1(fn vin ->
        check =
          case vget(vin, "check") do
            "gt3" -> fn {_k, x} -> is_number(x) and not is_boolean(x) and x > 3 end
            "lt3" -> fn {_k, x} -> is_number(x) and not is_boolean(x) and x < 3 end
            _ -> fn _ -> false end
          end

        S.filter(vget(vin, "val"), check)
      end)
    )

    withnull.(
      "minor",
      "typename",
      arg1(fn v -> S.typename(if(is_number(v) and not is_boolean(v), do: trunc(v), else: 0)) end)
    )

    withnull.(
      "minor",
      "flatten",
      arg1(fn vin ->
        d = vget(vin, "depth")
        S.flatten(vget(vin, "val"), if(is_number(d), do: trunc(d), else: 1))
      end)
    )

    # --- walk ---

    runset.(single(spec, "walk", "log"), arg1(&walk_log_subject/1))

    withnull.(
      "walk",
      "basic",
      arg1(fn vin ->
        S.walk(vin,
          after: fn _k, v, _p, path -> if is_binary(v), do: v <> "~" <> joinpath(path), else: v end
        )
      end)
    )

    withnull.("walk", "copy", arg1(&walk_copy_subject/1))
    nonull.("walk", "depth", arg1(&walk_depth_subject/1))

    # --- merge ---

    runset.(single(spec, "merge", "basic"), arg1(fn v -> S.merge(S.clone(v)) end))
    withnull.("merge", "cases", arg1(fn v -> S.merge(v) end))
    withnull.("merge", "array", arg1(fn v -> S.merge(v) end))
    withnull.("merge", "integrity", arg1(fn v -> S.merge(v) end))
    withnull.("merge", "depth", arg1(fn vin -> S.merge(vget(vin, "val"), vget(vin, "depth")) end))

    # --- getpath ---

    withnull.(
      "getpath",
      "basic",
      arg1(fn vin -> S.getpath(vget(vin, "store"), vget(vin, "path")) end)
    )

    withnull.(
      "getpath",
      "relative",
      arg1(fn vin ->
        dp = vget(vin, "dpath")
        dpath = if is_binary(dp), do: S.jt(String.split(dp, ".")), else: nil
        injdef = S.jm(["dparent", vget(vin, "dparent"), "dpath", dpath])
        S.getpath(vget(vin, "store"), vget(vin, "path"), injdef)
      end)
    )

    withnull.(
      "getpath",
      "special",
      arg1(fn vin -> S.getpath(vget(vin, "store"), vget(vin, "path"), vget(vin, "inj")) end)
    )

    withnull.(
      "getpath",
      "handler",
      arg1(fn vin ->
        store = S.jm(["$TOP", vget(vin, "store"), "$FOO", fn -> "foo" end])
        handler = fn _inj, val, _ref, _st -> if S.isfunc(val), do: val.(), else: val end
        S.getpath(store, vget(vin, "path"), S.jm(["handler", handler]))
      end)
    )

    # --- inject ---

    runset.(
      single(spec, "inject", "basic"),
      arg1(fn vin -> S.inject(S.clone(vget(vin, "val")), S.clone(vget(vin, "store"))) end)
    )

    withnull.(
      "inject",
      "string",
      arg1(fn vin ->
        S.inject(
          vget(vin, "val"),
          vget(vin, "store"),
          S.jm(["modify", &O.null_modifier/4, "extra", vget(vin, "current")])
        )
      end)
    )

    withnull.("inject", "deep", arg1(fn vin -> S.inject(vget(vin, "val"), vget(vin, "store")) end))

    # --- transform ---

    runset.(
      single(spec, "transform", "basic"),
      arg1(fn vin -> S.transform(S.getprop(vin, "data"), S.getprop(vin, "spec")) end)
    )

    Enum.each(["paths", "cmds", "each", "pack", "ref", "apply"], fn sub ->
      withnull.("transform", sub, arg1(fn vin -> S.transform(vget(vin, "data"), vget(vin, "spec")) end))
    end)

    withnull.(
      "transform",
      "modify",
      arg1(fn vin ->
        modifier = fn v, key, parent, _inj ->
          if is_binary(v) and key != nil and parent != nil, do: S.setprop(parent, key, "@" <> v)
        end

        S.transform(
          vget(vin, "data"),
          vget(vin, "spec"),
          S.jm(["modify", modifier, "extra", vget(vin, "store")])
        )
      end)
    )

    nonull.(
      "transform",
      "format",
      arg1(fn vin -> S.transform(vget(vin, "data"), vget(vin, "spec")) end)
    )

    # --- validate ---

    nonull.("validate", "basic", arg1(fn vin -> S.validate(vget(vin, "data"), vget(vin, "spec")) end))

    Enum.each(["child", "one", "exact"], fn sub ->
      withnull.("validate", sub, arg1(fn vin -> S.validate(vget(vin, "data"), vget(vin, "spec")) end))
    end)

    nonull.(
      "validate",
      "invalid",
      arg1(fn vin -> S.validate(vget(vin, "data"), vget(vin, "spec")) end)
    )

    withnull.(
      "validate",
      "special",
      arg1(fn vin -> S.validate(vget(vin, "data"), vget(vin, "spec"), vget(vin, "inj")) end)
    )

    # --- select ---

    Enum.each(["basic", "operators", "edge", "alts"], fn sub ->
      withnull.("select", sub, arg1(fn vin -> S.select(vget(vin, "obj"), vget(vin, "query")) end))
    end)

    # --- nullsem ---
    #
    # Does a PRESENT key holding a JSON null read as "no value"? Elixir CAN
    # store one - `setprop` writes nil rather than deleting, and `keysof`
    # reports the key - so unlike the ports that cannot express a stored null
    # at all, this lane asserts something. All lanes are {null: false}: the
    # whole question is what a real null does.

    nonull.(
      "nullsem",
      "getprop",
      arg1(fn vin ->
        if vhas(vin, "alt"),
          do: S.getprop(vget(vin, "val"), vget(vin, "key"), vget(vin, "alt")),
          else: S.getprop(vget(vin, "val"), vget(vin, "key"))
      end)
    )

    nonull.(
      "nullsem",
      "getelem",
      arg1(fn vin ->
        if vhas(vin, "alt"),
          do: S.getelem(vget(vin, "val"), vget(vin, "key"), vget(vin, "alt")),
          else: S.getelem(vget(vin, "val"), vget(vin, "key"))
      end)
    )

    nonull.("nullsem", "getpath", arg1(fn vin -> S.getpath(vget(vin, "store"), vget(vin, "path")) end))
    nonull.("nullsem", "haskey", arg1(fn vin -> S.haskey(vget(vin, "src"), vget(vin, "key")) end))
    nonull.("nullsem", "keysof", arg1(fn v -> S.keysof(v) |> S.jt() end))

    ran = O.cases()
    IO.puts("\nSTRUCT CORPUS: CASES #{ran} (vendored omni)")

    # A run that executes nothing is not a pass. The floor is the corpus as
    # measured at the vendoring tag, less the four guarded drops above; it is
    # deliberately a FLOOR, so the corpus can grow without editing this line,
    # and a section that stopped running trips it.
    assert ran >= 1208, "the struct corpus executed only #{ran} cases"
  end
end
