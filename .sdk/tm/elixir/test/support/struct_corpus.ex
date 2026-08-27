# Vendored struct corpus runner for the Univec SDK.
#
# Runs the shared JSON corpus (.sdk/test/test.json -> "struct") through the
# vendored Voxgig.Struct implementation. Mirrors the runner shipped with the
# struct port (fixJson / eqv / doMatch / matchval / runSet / runSingle).
# run/1 returns {npass, nfail, failures}.

defmodule Univec.StructCorpus do
  alias Voxgig.Struct, as: S
  alias Voxgig.Struct.Error, as: SE
  alias Univec.Utility, as: U

  @nullmark "__NULL__"
  @undefmark "__UNDEF__"
  @existsmark "__EXISTS__"

  # --- minimal JSON parser -> heap nodes -----------------------------------

  defp parse(str) do
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

  # --- node helpers --------------------------------------------------------

  defp velems(v) do
    if S.islist(v) do
      n = S.size(v)
      if n == 0, do: [], else: Enum.map(0..(n - 1), fn i -> S.getelem(v, i) end)
    else
      []
    end
  end

  defp ehas(e, k), do: S.ismap(e) and Enum.member?(S.keysof(e), k)
  defp eget(e, k), do: if(S.ismap(e), do: S.getprop(e, k), else: nil)

  defp jss(v) do
    cond do
      v == nil -> "null"
      is_binary(v) -> v
      true -> S.stringify(v)
    end
  end

  defp joinpath(path), do: velems(path) |> Enum.map(&jss/1) |> Enum.join(".")

  # --- fixJson -------------------------------------------------------------

  defp fixj(v, flag) do
    cond do
      v == nil ->
        if flag, do: @nullmark, else: nil

      S.ismap(v) ->
        Enum.each(S.keysof(v), fn k -> S.setprop(v, k, fixj(S.getprop(v, k), flag)) end)
        v

      S.islist(v) ->
        n = S.size(v)
        if n > 0, do: Enum.each(0..(n - 1), fn i -> S.setprop(v, i, fixj(S.getelem(v, i), flag)) end)
        v

      true ->
        v
    end
  end

  # --- eqv / matchval / doMatch --------------------------------------------

  defp eqv(a, b) do
    cond do
      a == nil and b == nil -> true
      is_boolean(a) or is_boolean(b) -> a === b
      is_number(a) and is_number(b) -> a == b
      is_binary(a) and is_binary(b) -> a == b
      S.islist(a) and S.islist(b) -> eqv_list(a, b)
      S.ismap(a) and S.ismap(b) -> eqv_map(a, b)
      true -> a === b
    end
  end

  defp eqv_list(a, b) do
    S.size(a) == S.size(b) and
      Enum.all?(velems(a) |> Enum.zip(velems(b)), fn {x, y} -> eqv(x, y) end)
  end

  defp eqv_map(a, b) do
    ka = S.keysof(a)
    kb = S.keysof(b)
    Enum.sort(ka) == Enum.sort(kb) and Enum.all?(ka, fn k -> eqv(S.getprop(a, k), S.getprop(b, k)) end)
  end

  defp matchval(check0, base) do
    check = if check0 == @undefmark or check0 == @nullmark, do: nil, else: check0

    cond do
      eqv(check, base) ->
        true

      is_binary(check) ->
        basestr = S.stringify(base)

        if String.length(check) >= 2 and String.starts_with?(check, "/") and
             String.ends_with?(check, "/") do
          pat = String.slice(check, 1, String.length(check) - 2)
          Regex.match?(Regex.compile!(pat), basestr)
        else
          String.contains?(String.downcase(basestr), String.downcase(S.stringify(check)))
        end

      S.isfunc(check) ->
        true

      true ->
        false
    end
  end

  defp do_match(check, base0) do
    base = S.clone(base0)

    S.walk(check,
      before: fn _k, v, _p, path ->
        if not S.isnode(v) do
          baseval = S.getpath(base, path)

          cond do
            eqv(baseval, v) -> :ok
            v == @undefmark and baseval == nil -> :ok
            v == @existsmark and baseval != nil -> :ok
            not matchval(v, baseval) ->
              raise SE,
                message:
                  "MATCH: " <>
                    joinpath(path) <>
                    ": [" <> S.stringify(v) <> "] <=> [" <> S.stringify(baseval) <> "]"

            true -> :ok
          end
        end

        v
      end
    )
  end

  # --- recording -----------------------------------------------------------

  defp record(_group, _name, true, _msg), do: Process.put(:npass, Process.get(:npass, 0) + 1)

  defp record(group, name, false, msg) do
    Process.put(:nfail, Process.get(:nfail, 0) + 1)
    Process.put(:failures, Process.get(:failures, []) ++ ["FAIL #{group} #{name} - #{msg}"])
  end

  defp errmsg(%SE{message: m}), do: m
  defp errmsg(%{message: m}) when is_binary(m), do: m
  defp errmsg(e), do: Exception.message(e)

  # --- resolveArgs / checkResult / handleError -----------------------------

  defp resolve_args(entry) do
    cond do
      ehas(entry, "ctx") -> [eget(entry, "ctx")]
      ehas(entry, "args") ->
        a = eget(entry, "args")

        if S.islist(a) do
          args = velems(a)
          # ts's resolveArgs writes the live first arg back as entry.ctx, so a
          # `match: {ctx: ...}` resolves for args-style entries too. Without it
          # every such assertion reads null and asserts nothing.
          case args do
            [first | _] -> if S.ismap(first), do: S.setprop(entry, "ctx", first)
            _ -> :ok
          end

          args
        else
          []
        end
      ehas(entry, "in") -> [S.clone(eget(entry, "in"))]
      true -> []
    end
  end

  defp check_result(entry, args, res) do
    matched =
      if ehas(entry, "match") do
        do_match(
          eget(entry, "match"),
          S.jm(["in", eget(entry, "in"), "args", S.jt(args), "out", eget(entry, "res"), "ctx", eget(entry, "ctx")])
        )

        true
      else
        false
      end

    out = eget(entry, "out")

    cond do
      eqv(out, res) -> :ok
      matched and (out == @nullmark or out == nil) -> :ok
      true -> raise SE, message: "Expected: #{S.stringify(out)}, got: #{S.stringify(res)}"
    end
  end

  defp handle_error(entry, err) do
    msg = errmsg(err)

    if ehas(entry, "err") do
      entry_err = eget(entry, "err")

      if entry_err == true or matchval(entry_err, msg) do
        if ehas(entry, "match") do
          do_match(
            eget(entry, "match"),
            # ts hands do_match the ERROR OBJECT, so a corpus
            # `match: {err: {message: ...}}` resolves; a bare string leaves
            # err.message reading null.
            S.jm([
              "in", eget(entry, "in"), "out", eget(entry, "res"),
              "ctx", eget(entry, "ctx"), "err", S.jm(["message", msg])
            ])
          )
        end

        :ok
      else
        raise SE, message: "ERROR MATCH: [#{S.stringify(entry_err)}] <=> [#{msg}]"
      end
    else
      raise err
    end
  end

  # --- runSet / runSingle --------------------------------------------------

  defp run_set(group, node, subject, flag_null \\ true) do
    fixed = fixj(S.clone(node), flag_null)
    testset = S.getprop(fixed, "set")

    if S.islist(testset) do
      Enum.each(velems(testset), fn entry ->
        name = jss(eget(entry, "name"))

        try do
          if not ehas(entry, "out") and flag_null, do: S.setprop(entry, "out", @nullmark)
          args = resolve_args(entry)
          res = fixj(subject.(args), flag_null)
          S.setprop(entry, "res", res)
          check_result(entry, args, res)
          record(group, name, true, "")
        rescue
          e ->
            try do
              handle_error(entry, e)
              record(group, name, true, "")
            rescue
              e2 -> record(group, name, false, errmsg(e2))
            end
        end
      end)
    end
  end

  defp run_single(group, node, fun) do
    try do
      expected = eget(node, "out")
      actual = fun.(eget(node, "in"))

      if eqv(expected, actual) do
        record(group, "single", true, "")
      else
        record(group, "single", false, "Expected: #{S.stringify(expected)}, got: #{S.stringify(actual)}")
      end
    rescue
      e -> record(group, "single", false, errmsg(e))
    end
  end

  # --- subject helpers -----------------------------------------------------

  defp arg1(f), do: fn args -> f.(if(args == [], do: nil, else: hd(args))) end
  defp vget(vin, k), do: if(S.ismap(vin), do: S.getprop(vin, k), else: nil)
  defp vhas(vin, k), do: S.ismap(vin) and Enum.member?(S.keysof(vin), k)

  defp grow_list(c, i) do
    if S.size(c) <= i do
      S.setprop(c, S.size(c), nil)
      grow_list(c, i)
    end
  end

  defp null_modifier(v, key, parent, _inj) do
    cond do
      v == @nullmark -> S.setprop(parent, key, nil)
      is_binary(v) -> S.setprop(parent, key, String.replace(v, @nullmark, "null"))
      true -> :ok
    end
  end

  defp walk_copy_subject(vin) do
    cur = S.jt([nil])

    walkcopy = fn key, v, _parent, path ->
      if key == nil do
        inner = S.jt([cond do; S.ismap(v) -> S.jm([]); S.islist(v) -> S.jt([]); true -> v end])
        S.setprop(cur, 0, inner)
      else
        i = S.size(path)

        nv =
          if S.isnode(v) do
            c = S.getelem(cur, 0)
            grow_list(c, i)
            nvx = if S.ismap(v), do: S.jm([]), else: S.jt([])
            S.setprop(c, i, nvx)
            nvx
          else
            v
          end

        S.setprop(S.getelem(S.getelem(cur, 0), i - 1), key, nv)
      end

      v
    end

    S.walk(vin, before: walkcopy)
    S.getelem(S.getelem(cur, 0), 0)
  end

  defp walk_depth_subject(vin) do
    state = S.jm(["top", nil, "cur", nil])

    copy = fn key, v, _parent, _path ->
      if key == nil or S.isnode(v) do
        child = if S.islist(v), do: S.jt([]), else: S.jm([])

        if key == nil do
          S.setprop(state, "top", child)
          S.setprop(state, "cur", child)
        else
          S.setprop(S.getprop(state, "cur"), key, child)
          S.setprop(state, "cur", child)
        end
      else
        S.setprop(S.getprop(state, "cur"), key, v)
      end

      v
    end

    S.walk(vget(vin, "src"), before: copy, maxdepth: vget(vin, "maxdepth"))
    S.getprop(state, "top")
  end

  defp run_walk_log(group, node) do
    try do
      test_data = S.clone(node)
      log = S.jt([])

      walklog = fn key, v, parent, path ->
        S.setprop(
          log,
          S.size(log),
          "k=" <>
            (if key == nil, do: S.stringify(), else: S.stringify(key)) <>
            ", v=" <>
            S.stringify(v) <>
            ", p=" <>
            (if parent == nil, do: S.stringify(), else: S.stringify(parent)) <>
            ", t=" <>
            S.pathify(path)
        )

        v
      end

      S.walk(S.getprop(test_data, "in"), after: walklog)
      expected = S.getprop(S.getprop(test_data, "out"), "after")

      if eqv(expected, log) do
        record(group, "log", true, "")
      else
        record(group, "log", false, "Expected: #{S.stringify(expected)}, got: #{S.stringify(log)}")
      end
    rescue
      e -> record(group, "log", false, errmsg(e))
    end
  end

  # --- runAll --------------------------------------------------------------

  defp run_all(spec) do
    g = fn k -> S.getprop(spec, k) end
    minor = g.("minor")
    walks = g.("walk")
    merges = g.("merge")
    getpaths = g.("getpath")
    injects = g.("inject")
    transforms = g.("transform")
    validates = g.("validate")
    selects = g.("select")
    sentinels = g.("sentinels")
    mg = fn n -> S.getprop(minor, n) end

    run_set("minor.isnode", mg.("isnode"), arg1(fn v -> S.isnode(v) end))
    run_set("minor.ismap", mg.("ismap"), arg1(fn v -> S.ismap(v) end))
    run_set("minor.islist", mg.("islist"), arg1(fn v -> S.islist(v) end))
    run_set("minor.iskey", mg.("iskey"), arg1(fn v -> S.iskey(v) end), false)
    run_set("minor.strkey", mg.("strkey"), arg1(fn v -> S.strkey(v) end), false)
    run_set("minor.isempty", mg.("isempty"), arg1(fn v -> S.isempty(v) end), false)
    run_set("minor.isfunc", mg.("isfunc"), arg1(fn v -> S.isfunc(v) end))
    run_set("minor.clone", mg.("clone"), arg1(fn v -> S.clone(v) end), false)
    run_set("minor.escre", mg.("escre"), arg1(fn v -> S.escre(v) end))
    run_set("minor.escurl", mg.("escurl"), arg1(fn v -> S.escurl(v) end))

    run_set(
      "minor.stringify",
      mg.("stringify"),
      arg1(fn vin ->
        if vhas(vin, "val"), do: S.stringify(vget(vin, "val"), vget(vin, "max")), else: S.stringify()
      end),
      false
    )

    run_set("minor.jsonify", mg.("jsonify"), arg1(fn vin -> S.jsonify(vget(vin, "val"), vget(vin, "flags")) end), false)

    run_set(
      "minor.getelem",
      mg.("getelem"),
      arg1(fn vin ->
        alt = vget(vin, "alt")
        if alt == nil, do: S.getelem(vget(vin, "val"), vget(vin, "key")), else: S.getelem(vget(vin, "val"), vget(vin, "key"), alt)
      end),
      false
    )

    run_set("minor.delprop", mg.("delprop"), arg1(fn vin -> S.delprop(vget(vin, "parent"), vget(vin, "key")) end))
    run_set("minor.size", mg.("size"), arg1(fn v -> S.size(v) end), false)
    run_set("minor.slice", mg.("slice"), arg1(fn vin -> S.slice(vget(vin, "val"), vget(vin, "start"), vget(vin, "end")) end), false)
    run_set("minor.pad", mg.("pad"), arg1(fn vin -> S.pad(vget(vin, "val"), vget(vin, "pad"), vget(vin, "char")) end), false)

    run_set(
      "minor.pathify",
      mg.("pathify"),
      arg1(fn vin ->
        if vhas(vin, "path"), do: S.pathify(vget(vin, "path"), vget(vin, "from")), else: S.pathify(S.noarg(), vget(vin, "from"))
      end),
      false
    )

    run_set("minor.items", mg.("items"), arg1(fn v -> S.items(v) end))

    run_set(
      "minor.getprop",
      mg.("getprop"),
      arg1(fn vin ->
        alt = vget(vin, "alt")
        if alt == nil, do: S.getprop(vget(vin, "val"), vget(vin, "key")), else: S.getprop(vget(vin, "val"), vget(vin, "key"), alt)
      end),
      false
    )

    run_set("minor.setprop", mg.("setprop"), arg1(fn vin -> S.setprop(vget(vin, "parent"), vget(vin, "key"), vget(vin, "val")) end))
    run_set("minor.haskey", mg.("haskey"), arg1(fn vin -> S.haskey(vget(vin, "src"), vget(vin, "key")) end), false)
    run_set("minor.keysof", mg.("keysof"), arg1(fn v -> S.keysof(v) |> S.jt() end))
    run_set("minor.join", mg.("join"), arg1(fn vin -> S.join(vget(vin, "val"), vget(vin, "sep"), vget(vin, "url")) end), false)
    run_set("minor.typify", mg.("typify"), fn args -> S.typify(if(args == [], do: S.noarg(), else: hd(args))) end, false)
    run_set("minor.setpath", mg.("setpath"), arg1(fn vin -> S.setpath(vget(vin, "store"), vget(vin, "path"), vget(vin, "val")) end), false)

    run_set("minor.filter", mg.("filter"), arg1(fn vin ->
      c = vget(vin, "check")

      check =
        case c do
          "gt3" -> fn {_k, x} -> is_number(x) and not is_boolean(x) and x > 3 end
          "lt3" -> fn {_k, x} -> is_number(x) and not is_boolean(x) and x < 3 end
          _ -> fn _ -> false end
        end

      S.filter(vget(vin, "val"), check)
    end))

    run_set("minor.typename", mg.("typename"), arg1(fn v -> S.typename(if(is_number(v) and not is_boolean(v), do: trunc(v), else: 0)) end))

    run_set("minor.flatten", mg.("flatten"), arg1(fn vin ->
      d = vget(vin, "depth")
      S.flatten(vget(vin, "val"), if(is_number(d), do: trunc(d), else: 1))
    end))

    run_walk_log("walk.log", S.getprop(walks, "log"))

    run_set("walk.basic", S.getprop(walks, "basic"), arg1(fn vin ->
      S.walk(vin, after: fn _k, v, _p, path ->
        if is_binary(v), do: v <> "~" <> joinpath(path), else: v
      end)
    end))

    run_set("walk.copy", S.getprop(walks, "copy"), arg1(&walk_copy_subject/1))
    run_set("walk.depth", S.getprop(walks, "depth"), arg1(&walk_depth_subject/1), false)

    run_single("merge.basic", S.getprop(merges, "basic"), fn in_ -> S.merge(S.clone(in_)) end)
    run_set("merge.cases", S.getprop(merges, "cases"), arg1(fn v -> S.merge(v) end))
    run_set("merge.array", S.getprop(merges, "array"), arg1(fn v -> S.merge(v) end))
    run_set("merge.integrity", S.getprop(merges, "integrity"), arg1(fn v -> S.merge(v) end))
    run_set("merge.depth", S.getprop(merges, "depth"), arg1(fn vin -> S.merge(vget(vin, "val"), vget(vin, "depth")) end))

    run_set("getpath.basic", S.getprop(getpaths, "basic"), arg1(fn vin -> S.getpath(vget(vin, "store"), vget(vin, "path")) end))

    run_set("getpath.relative", S.getprop(getpaths, "relative"), arg1(fn vin ->
      dp = vget(vin, "dpath")
      dpath = if is_binary(dp), do: S.jt(String.split(dp, ".")), else: nil
      injdef = S.jm(["dparent", vget(vin, "dparent"), "dpath", dpath])
      S.getpath(vget(vin, "store"), vget(vin, "path"), injdef)
    end))

    run_set("getpath.special", S.getprop(getpaths, "special"), arg1(fn vin ->
      S.getpath(vget(vin, "store"), vget(vin, "path"), vget(vin, "inj"))
    end))

    run_set("getpath.handler", S.getprop(getpaths, "handler"), arg1(fn vin ->
      store = S.jm(["$TOP", vget(vin, "store"), "$FOO", fn -> "foo" end])
      handler = fn _inj, val, _ref, _st -> if S.isfunc(val), do: val.(), else: val end
      S.getpath(store, vget(vin, "path"), S.jm(["handler", handler]))
    end))

    run_single("inject.basic", S.getprop(injects, "basic"), fn in_ ->
      S.inject(S.clone(S.getprop(in_, "val")), S.clone(S.getprop(in_, "store")))
    end)

    run_set("inject.string", S.getprop(injects, "string"), arg1(fn vin ->
      S.inject(vget(vin, "val"), vget(vin, "store"), S.jm(["modify", &null_modifier/4, "extra", vget(vin, "current")]))
    end))

    run_set("inject.deep", S.getprop(injects, "deep"), arg1(fn vin -> S.inject(vget(vin, "val"), vget(vin, "store")) end))

    run_single("transform.basic", S.getprop(transforms, "basic"), fn in_ ->
      S.transform(S.getprop(in_, "data"), S.getprop(in_, "spec"))
    end)

    Enum.each(["paths", "cmds", "each", "pack", "ref"], fn gn ->
      run_set("transform.#{gn}", S.getprop(transforms, gn), arg1(fn vin -> S.transform(vget(vin, "data"), vget(vin, "spec")) end))
    end)

    run_set("transform.modify", S.getprop(transforms, "modify"), arg1(fn vin ->
      modifier = fn v, key, parent, _inj ->
        if is_binary(v) and key != nil and parent != nil, do: S.setprop(parent, key, "@" <> v)
      end

      S.transform(vget(vin, "data"), vget(vin, "spec"), S.jm(["modify", modifier, "extra", vget(vin, "store")]))
    end))

    run_set("transform.format", S.getprop(transforms, "format"), arg1(fn vin -> S.transform(vget(vin, "data"), vget(vin, "spec")) end), false)
    run_set("transform.apply", S.getprop(transforms, "apply"), arg1(fn vin -> S.transform(vget(vin, "data"), vget(vin, "spec")) end))

    run_set("validate.basic", S.getprop(validates, "basic"), arg1(fn vin -> S.validate(vget(vin, "data"), vget(vin, "spec")) end), false)

    Enum.each(["child", "one", "exact"], fn gn ->
      run_set("validate.#{gn}", S.getprop(validates, gn), arg1(fn vin -> S.validate(vget(vin, "data"), vget(vin, "spec")) end))
    end)

    run_set("validate.invalid", S.getprop(validates, "invalid"), arg1(fn vin -> S.validate(vget(vin, "data"), vget(vin, "spec")) end), false)
    run_set("validate.special", S.getprop(validates, "special"), arg1(fn vin -> S.validate(vget(vin, "data"), vget(vin, "spec"), vget(vin, "inj")) end))

    Enum.each(["basic", "operators", "edge", "alts"], fn gn ->
      run_set("select.#{gn}", S.getprop(selects, gn), arg1(fn vin -> S.select(vget(vin, "obj"), vget(vin, "query")) end))
    end)

    if sentinels != nil do
      run_set("sentinels.getprop_unify", S.getprop(sentinels, "getprop_unify"), arg1(fn vin -> S.getprop(vget(vin, "val"), vget(vin, "key"), vget(vin, "alt")) end), false)
      run_set("sentinels.getelem_absent", S.getprop(sentinels, "getelem_absent"), arg1(fn vin -> S.getelem(vget(vin, "val"), vget(vin, "key"), vget(vin, "alt")) end), false)
      run_set("sentinels.haskey_unify", S.getprop(sentinels, "haskey_unify"), arg1(fn vin -> S.haskey(vget(vin, "val"), vget(vin, "key")) end), false)
      run_set("sentinels.isempty_unify", S.getprop(sentinels, "isempty_unify"), arg1(fn v -> S.isempty(v) end), false)
      run_set("sentinels.isnode_unify", S.getprop(sentinels, "isnode_unify"), arg1(fn v -> S.isnode(v) end), false)
      run_set("sentinels.stringify_null", S.getprop(sentinels, "stringify_null"), arg1(fn vin -> S.stringify(vin) end), false)
    end
  end

  # --- public entry --------------------------------------------------------

  def run(testfile \\ nil) do
    Process.put(:npass, 0)
    Process.put(:nfail, 0)
    Process.put(:failures, [])

    testfile = testfile || Path.join(File.cwd!(), "../.sdk/test/test.json")
    raw = File.read!(testfile)
    alltests = parse(raw)
    spec = S.getprop(alltests, "struct")
    run_all(spec)

    {Process.get(:npass, 0), Process.get(:nfail, 0), Process.get(:failures, [])}
  end

  # --- PRIMARY corpus ------------------------------------------------------
  #
  # Drives .sdk/test/test.json -> "primary", the same language-neutral corpus
  # the ts/js/lua/lean suites execute, through THIS SDK's request-shaping
  # utilities. Before this, elixir mirrored the corpus by hand, so its cases
  # could drift from the reference without anything noticing.
  #
  # The harness below is run_set's, with one difference: the subject receives
  # the ENTRY rather than resolved args, because the args-style sections have
  # to publish the context they build back onto the entry — a `match: ctx:`
  # assertion reads it from there.

  # A struct VALUE is itself a 2-tuple — {:vmap, id}, {:vlist, id}, {:vinj, id}
  # — so a bare `{res, err}` clause destructures a perfectly good map into
  # res=:vmap, err=<heap id>, and the run then fails with the heap id as its
  # error message. Match the value shapes first.
  defp pnorm({:vmap, _} = v), do: {v, nil}
  defp pnorm({:vlist, _} = v), do: {v, nil}
  defp pnorm({:vinj, _} = v), do: {v, nil}
  defp pnorm({res, err}), do: {res, err}
  defp pnorm(res), do: {res, nil}

  # A ctx for a ctx-style entry: the corpus supplies it, the client supplies
  # what makes it live (utility dispatch, options, config).
  defp pctx(entry, util, opts, config) do
    ctxmap = if ehas(entry, "ctx") and S.ismap(eget(entry, "ctx")), do: eget(entry, "ctx"), else: S.jm([])
    ctx = pbuild(ctxmap, util, opts, config)
    S.setprop(entry, "ctx", ctx)
    ctx
  end

  # A LIVE context from a corpus map. The corpus carries spec/result/response
  # as plain JSON; the utilities read and MUTATE them through Spec/Result/
  # Response, so a bare map leaves them with nothing to work on — every
  # `match: ctx.result.*` assertion then reads null, and prepare_* returns
  # nothing. Mirrors make_ctx_from_map in the lua/js reference drivers.
  defp pbuild(ctxmap, util, opts, config) do
    ctx = Univec.Context.new(ctxmap, nil)
    S.setprop(ctx, "utility", util)
    S.setprop(ctx, "config", config)
    # THE CLIENT IS OPT-IN. Some utilities read their defaults off it —
    # prepare_headers reads opts_map(ctx.client) — but the client holds the
    # root ctx, which holds the client, so anything that WALKS a ctx carrying
    # one never terminates: makeContext returns a ctx, and make_error raises an
    # error whose `ctx:` field is the ctx. Both hung the run until ExUnit
    # killed it. Only the sections that need client defaults ask for it.
    if Process.get(:pwantclient) == true and Process.get(:pclient) != nil,
      do: S.setprop(ctx, "client", Process.get(:pclient))
    if S.getprop(ctx, "options") == nil, do: S.setprop(ctx, "options", opts)

    specmap = S.getprop(ctxmap, "spec")
    if S.ismap(specmap), do: S.setprop(ctx, "spec", Univec.Spec.new(specmap))

    resmap = S.getprop(ctxmap, "result")

    if S.ismap(resmap) do
      result = Univec.Result.new(resmap)
      errmap = S.getprop(resmap, "err")

      if S.ismap(errmap) do
        msg = jss(S.getprop(errmap, "message"))
        if is_binary(msg) and msg != "",
          do: S.setprop(result, "err", Univec.Error.new("", msg, nil))
      end

      S.setprop(ctx, "result", result)
    end

    respmap = S.getprop(ctxmap, "response")

    if S.ismap(respmap) do
      response = Univec.Response.new(respmap)
      body = S.getprop(respmap, "body")
      if body != nil, do: S.setprop(response, "json_func", fn -> body end)

      hdrs = S.getprop(respmap, "headers")

      if S.ismap(hdrs) do
        lower = S.jm([])
        Enum.each(S.keysof(hdrs), fn k ->
          S.setprop(lower, String.downcase(k), S.getprop(hdrs, k))
        end)
        S.setprop(response, "headers", lower)
      end

      S.setprop(ctx, "response", response)
    end

    ctx
  end

  # A ctx from a bare map (args-style sections), published back onto the entry.
  defp pmapctx(entry, v, util, opts, config) do
    ctx = pbuild(if(S.ismap(v), do: v, else: S.jm([])), util, opts, config)
    S.setprop(entry, "ctx", ctx)
    ctx
  end

  # A ctx that carries the client, for the sections whose utilities read their
  # defaults off it. Scoped so nothing else inherits the cycle.
  defp pctx_client(entry, util, opts, config) do
    Process.put(:pwantclient, true)
    ctx = pctx(entry, util, opts, config)
    Process.put(:pwantclient, false)
    ctx
  end

  defp parg(entry, i) do
    a = eget(entry, "args")
    if S.islist(a), do: Enum.at(velems(a), i), else: nil
  end

  defp run_primary_set(group, node, subject) do
    if System.get_env("VOX_DBG"), do: IO.puts("SECTION #{group}")
    fixed = fixj(S.clone(node), true)
    testset = S.getprop(fixed, "set")

    if S.islist(testset) do
      Enum.each(velems(testset), fn entry ->
        name = jss(eget(entry, "name"))

        try do
          if not ehas(entry, "out"), do: S.setprop(entry, "out", @nullmark)
          {res0, err} = pnorm(subject.(entry))

          if err != nil do
            raise SE, message: perrmsg(err)
          end

          # The RESULT can carry them too — makeContext returns a context — and
          # fixj walks it before anything else gets the chance to strip.
          if S.ismap(res0) do
            S.delprop(res0, "client")
            S.delprop(res0, "utility")
          end

          res = fixj(res0, true)
          S.setprop(entry, "res", res)

          # STRIP THE LIVE REFERENCES BEFORE MATCHING. check_result matches
          # against entry.ctx, and the ctx carries the client so utilities like
          # prepare_headers can read their defaults off it. The client holds the
          # root ctx, which holds the client — walking that is a cycle, and the
          # run hangs until ExUnit kills it at 60s. The utilities have already
          # run by here, so nothing needs them any more.
          ectx = eget(entry, "ctx")

          if S.ismap(ectx) do
            S.delprop(ectx, "client")
            S.delprop(ectx, "utility")
          end

          check_result(entry, resolve_args(entry), res)
          record(group, name, true, "")
        rescue
          e ->
            try do
              handle_error(entry, e)
              record(group, name, true, "")
            rescue
              e2 -> record(group, name, false, errmsg(e2))
            end
        end
      end)
    end
  end

  # The corpus speaks camelCase; snake_case languages do not. lua, py and
  # elixir all store `status_text` internally while reading `statusText` off
  # the wire, so a `match: ctx.result.statusText` assertion reads null unless
  # the driver publishes a neutral-named view back. The lua reference driver
  # does exactly this.
  defp pneutral_result(result) do
    if S.ismap(result) do
      err = S.getprop(result, "err")

      S.jm([
        "ok", S.getprop(result, "ok"),
        "status", S.getprop(result, "status"),
        "statusText", S.getprop(result, "status_text"),
        "headers", S.getprop(result, "headers"),
        "body", S.getprop(result, "body"),
        "err", if(err == nil, do: nil, else: S.jm(["message", perrmsg(err)]))
      ])
    end
  end

  # Publish the neutral view of ctx.result onto the entry's ctx, so
  # `match: ctx.result.*` sees corpus-shaped data.
  defp ppub(entry, ctx) do
    ectx = eget(entry, "ctx")
    result = if S.ismap(ctx), do: S.getprop(ctx, "result")
    if S.ismap(ectx) and S.ismap(result) do
      S.setprop(ectx, "result", pneutral_result(result))
    end
    :ok
  end

  defp perrmsg(err) do
    cond do
      is_binary(err) -> err
      S.ismap(err) -> jss(S.getprop(err, "message")) || S.stringify(err)
      true -> inspect(err)
    end
  end

  defp psec(primary, name, sub \\ "basic"), do: S.getprop(S.getprop(primary, name), sub)

  # A CLIENT built from a section's DEF.setup.a block.
  #
  # prepare_auth reads opts_map(ctx.client) — as the ts reference does, via
  # client.options() — so a section's setup options have to reach it through a
  # client, not through ctx.options. Passing them as options alone left the
  # apikey unreachable and the authorization header never set.
  defp pclient_for(primary, name) do
    setup = S.getprop(S.getprop(S.getprop(S.getprop(primary, name), "DEF"), "setup"), "a")
    if S.ismap(setup), do: Univec.test(nil, S.clone(setup)), else: Univec.test()
  end

  # Options built from a section's DEF.setup.a block, the way the reference
  # harness does. Falls back to the client's options when a section has none.
  defp psetup(primary, name, util, config) do
    setup =
      S.getprop(S.getprop(S.getprop(S.getprop(primary, name), "DEF"), "setup"), "a")

    ctx = S.jm([])
    S.setprop(ctx, "utility", util)
    S.setprop(ctx, "config", config)
    S.setprop(ctx, "options", if(S.ismap(setup), do: S.clone(setup), else: S.jm([])))
    U.make_options(ctx)
  end

  def run_primary(testfile \\ nil) do
    Process.put(:npass, 0)
    Process.put(:nfail, 0)
    Process.put(:failures, [])

    testfile = testfile || Path.join(File.cwd!(), "../.sdk/test/test.json")
    root = parse(File.read!(testfile))
    primary = S.getprop(root, "primary")

    client = Univec.test()
    Process.put(:pclient, client)
    Process.put(:pbaseclient, client)
    rootctx = Univec.get_root_ctx(client)
    util = S.getprop(rootctx, "utility")
    config = S.getprop(rootctx, "config")
    opts = S.getprop(rootctx, "options")

    run_primary_set("done", psec(primary, "done"), fn e ->
      U.done(pctx(e, util, opts, config))
    end)

    # makeContext takes a PLAIN map and returns a context; it needs no client
    # and no utility dispatch. Handing it a live ctx made Context.new copy the
    # client through, and fixj then walked client -> rootctx -> client.
    run_primary_set("makeContext", psec(primary, "makeContext"), fn e ->
      inv = eget(e, "in")
      ctxmap = if S.ismap(inv), do: inv, else: S.jm([])
      S.setprop(e, "ctx", ctxmap)
      Univec.Context.new(ctxmap, nil)
    end)

    run_primary_set("makeError", psec(primary, "makeError"), fn e ->
      ctx = pmapctx(e, parg(e, 0), util, opts, config)
      {nil, U.make_error(ctx, parg(e, 1))}
    end)

    run_primary_set("makeOptions", psec(primary, "makeOptions"), fn e ->
      inv = eget(e, "in")
      ctx = pmapctx(e, S.jm([]), util, opts, config)
      S.setprop(ctx, "config", S.getprop(inv, "config"))
      S.setprop(ctx, "options", S.getprop(inv, "options"))
      U.make_options(ctx)
    end)

    run_primary_set("makeRequest", psec(primary, "makeRequest"), fn e ->
      U.make_request(pctx(e, util, opts, config))
    end)

    run_primary_set("makeResponse", psec(primary, "makeResponse"), fn e ->
      ctx = pctx(e, util, opts, config)
      out = U.make_response(ctx)
      ppub(e, ctx)
      out
    end)

    # makeSpec and prepareAuth are configured by their own DEF.setup.a block,
    # not by the client's default options — the corpus supplies the base URL
    # and the api key the cases assert on.
    spec_opts = psetup(primary, "makeSpec", util, config)

    run_primary_set("makeSpec", psec(primary, "makeSpec"), fn e ->
      U.make_spec(pctx_client(e, util, spec_opts, config))
    end)

    run_primary_set("makeUrl", psec(primary, "makeUrl"), fn e ->
      U.make_url(pctx(e, util, opts, config))
    end)

    run_primary_set("operator", psec(primary, "operator"), fn e ->
      inv = eget(e, "in")
      op = Univec.Operation.new(if(S.ismap(inv), do: inv, else: S.jm([])))
      S.jm([
        "entity", S.getprop(op, "entity"),
        "input", S.getprop(op, "input"),
        "name", S.getprop(op, "name"),
        "points", S.getprop(op, "points")
      ])
    end)

    run_primary_set("param", psec(primary, "param"), fn e ->
      ctx = pmapctx(e, parg(e, 0), util, opts, config)
      U.param(ctx, parg(e, 1))
    end)

    auth_opts = psetup(primary, "prepareAuth", util, config)
    auth_client = pclient_for(primary, "prepareAuth")

    run_primary_set("prepareAuth", psec(primary, "prepareAuth"), fn e ->
      Process.put(:pclient, auth_client)
      out = U.prepare_auth(pctx_client(e, util, auth_opts, config))
      Process.put(:pclient, Process.get(:pbaseclient))
      out
    end)

    run_primary_set("prepareBody", psec(primary, "prepareBody"), fn e ->
      U.prepare_body(pctx(e, util, opts, config))
    end)

    run_primary_set("prepareHeaders", psec(primary, "prepareHeaders"), fn e ->
      U.prepare_headers(pctx_client(e, util, opts, config))
    end)

    run_primary_set("prepareMethod", psec(primary, "prepareMethod"), fn e ->
      U.prepare_method(pctx(e, util, opts, config))
    end)

    run_primary_set("prepareParams", psec(primary, "prepareParams"), fn e ->
      U.prepare_params(pctx(e, util, opts, config))
    end)

    run_primary_set("preparePath", psec(primary, "preparePath"), fn e ->
      U.prepare_path(pctx(e, util, opts, config))
    end)

    run_primary_set("prepareQuery", psec(primary, "prepareQuery"), fn e ->
      U.prepare_query(pctx(e, util, opts, config))
    end)

    run_primary_set("resultBasic", psec(primary, "resultBasic"), fn e ->
      ctx = pctx(e, util, opts, config)
      out = U.result_basic(ctx)
      ppub(e, ctx)
      if S.ismap(out) and S.getprop(out, "status_text") != nil,
        do: pneutral_result(out),
        else: out
    end)

    run_primary_set("resultBody", psec(primary, "resultBody"), fn e ->
      ctx = pctx(e, util, opts, config)
      out = U.result_body(ctx)
      ppub(e, ctx)
      if S.ismap(out) and S.getprop(out, "status_text") != nil,
        do: pneutral_result(out),
        else: out
    end)

    run_primary_set("resultHeaders", psec(primary, "resultHeaders"), fn e ->
      ctx = pctx(e, util, opts, config)
      out = U.result_headers(ctx)
      ppub(e, ctx)
      if S.ismap(out) and S.getprop(out, "status_text") != nil,
        do: pneutral_result(out),
        else: out
    end)

    run_primary_set("transformRequest", psec(primary, "transformRequest"), fn e ->
      U.transform_request(pctx(e, util, opts, config))
    end)

    run_primary_set("transformResponse", psec(primary, "transformResponse"), fn e ->
      U.transform_response(pctx(e, util, opts, config))
    end)

    {Process.get(:npass, 0), Process.get(:nfail, 0), Process.get(:failures, [])}
  end
end
