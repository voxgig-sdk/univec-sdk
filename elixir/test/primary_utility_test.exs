# Univec SDK primary-utility test
#
# The primary corpus (.sdk/test/test.json -> "primary") drives THIS SDK's
# request-shaping utilities through the VENDORED @voxgig/omni engine, via the
# resolver in test/support/omni.ex. The hand-written engine this suite used to
# call (test/support/struct_corpus.ex - its own runSet, resolveArgs,
# checkResult and doMatch, transcribed by hand) is retired: omni resolves
# arguments, applies the null rules and enforces out/err/match, so the
# subjects below only adapt each utility's calling convention. See
# docs/design/vendor-tag-rollout.md.
#
# Three conventions to know when adding a section:
#
# - A subject receives omni's RESOLVED ARGUMENT LIST in the SDK's value model.
#   For a ctx-style section that is the corpus ctx MAP, not a live context:
#   `livectx/2` materialises the real one from it, exactly as the retired
#   engine's make_ctx_from_map did.
#
# - Utilities that answer as a `{value, err}` PAIR go through `unwrap`, which
#   raises the err so omni can match it against an `err:` expectation. A
#   struct node is ITSELF a 2-tuple (`{:vmap, id}`), so `unwrap` matches the
#   value shapes first - destructuring one as a pair would hand the heap id
#   back as an error message.
#
# - `match: {ctx: ...}` is retargeted onto `match: {args: {"0": ...}}` by the
#   resolver (omni.ex decision 3), so a subject whose section asserts on
#   context state calls `sync/2` to write the observable live-context fields
#   back onto the ctx map it was given. That map is what omni matches.

defmodule Univec.PrimaryUtilityTest do
  use ExUnit.Case

  alias Voxgig.Struct, as: S
  alias Univec.Omni, as: O
  alias Univec.Utility, as: U

  setup_all do
    testfile = Path.join(File.cwd!(), "../.sdk/test/test.json")
    sdk = Univec.test()
    runner = O.make_runner(testfile, sdk)
    {:ok, run: runner.("primary"), sdk: sdk}
  end

  # --- corpus plumbing -----------------------------------------------------

  defp section(spec, name) do
    node = Map.get(Map.get(spec, name, %{}), "basic")

    assert is_map(node) and is_list(Map.get(node, "set")),
           "corpus section 'primary.#{name}' has no basic.set list - check the " <>
             "name against .sdk/test/primary/"

    assert [] != Map.get(node, "set"),
           "corpus section 'primary.#{name}' is EMPTY - zero cases would run; add " <>
             "cases, or mark the fixture PENDING in .sdk/test/primary/"

    node
  end

  # DEF.setup.a: a section's own client options (the base URL makeSpec
  # asserts on, the api key prepareAuth asserts on). Read from the corpus,
  # not invented here.
  defp setup_opts(spec, name) do
    setup = Map.get(Map.get(Map.get(spec, name, %{}), "DEF", %{}), "setup", %{})
    O.tostruct(Map.get(setup, "a", %{}))
  end

  # --- value plumbing ------------------------------------------------------

  # A struct VALUE is itself a 2-tuple - {:vmap, id}, {:vlist, id}, {:vinj,
  # id} - so a bare `{res, err}` clause destructures a perfectly good map
  # into res=:vmap, err=<heap id>. Match the value shapes FIRST.
  defp unwrap({:vmap, _} = val), do: val
  defp unwrap({:vlist, _} = val), do: val
  defp unwrap({:vinj, _} = val), do: val
  defp unwrap({_res, err}) when err != nil, do: raise(err)
  defp unwrap({res, _err}), do: res
  defp unwrap(res), do: res

  defp argnode(args, index) do
    val = Enum.at(args, index)
    if S.ismap(val), do: val, else: S.jm([])
  end

  # --- the live context ----------------------------------------------------

  # A LIVE context from the corpus's ctx map. The corpus carries
  # spec/result/response as plain JSON; the utilities read and MUTATE them
  # through Spec/Result/Response, so a bare map leaves them with nothing to
  # work on - every `match: ctx.result.*` assertion would then read null and
  # prepare_* would return nothing.
  #
  # THE CLIENT IS OPT-IN. Some utilities read their defaults off it
  # (prepare_headers reads the client's options), but the client holds the
  # root ctx which holds the client, so anything that WALKS a ctx carrying one
  # traverses a cycle. Only the sections that need client defaults ask for it.
  defp livectx(node, opts) do
    sdk = Keyword.fetch!(opts, :sdk)
    util = Univec.get_utility(sdk)
    rootctx = Univec.get_root_ctx(sdk)

    ctxmap = S.clone(node)
    S.delprop(ctxmap, "client")
    S.delprop(ctxmap, "utility")

    ctx = Univec.Context.new(ctxmap, nil)
    S.setprop(ctx, "utility", util)
    S.setprop(ctx, "config", S.getprop(rootctx, "config"))

    if Keyword.get(opts, :client, false), do: S.setprop(ctx, "client", sdk)

    if S.getprop(ctx, "options") == nil do
      S.setprop(ctx, "options", Keyword.get(opts, :options) || S.getprop(rootctx, "options"))
    end

    specmap = S.getprop(ctxmap, "spec")
    if S.ismap(specmap), do: S.setprop(ctx, "spec", Univec.Spec.new(specmap))

    resmap = S.getprop(ctxmap, "result")

    if S.ismap(resmap) do
      result = Univec.Result.new(resmap)
      errmap = S.getprop(resmap, "err")

      if S.ismap(errmap) do
        msg = S.getprop(errmap, "message")

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

  # The corpus speaks camelCase; snake_case ports do not. This one stores
  # `status_text` internally while reading `statusText` off the wire, so a
  # `result.statusText` assertion reads null unless a neutral-named view is
  # published back. lua and py carry the same translation.
  defp neutral_result(result) do
    if S.ismap(result) do
      err = S.getprop(result, "err")

      S.jm([
        "ok", S.getprop(result, "ok"),
        "status", S.getprop(result, "status"),
        "statusText", S.getprop(result, "status_text"),
        "headers", S.getprop(result, "headers"),
        "body", S.getprop(result, "body"),
        "err", if(err == nil, do: nil, else: S.jm(["message", errmsg(err)]))
      ])
    end
  end

  defp neutral_response(response) do
    if S.ismap(response) do
      S.jm([
        "status", S.getprop(response, "status"),
        "statusText", S.getprop(response, "status_text"),
        "headers", S.getprop(response, "headers"),
        "body", S.getprop(response, "body")
      ])
    end
  end

  defp errmsg(err) do
    cond do
      is_binary(err) -> err
      is_exception(err) -> Exception.message(err)
      S.ismap(err) -> S.getprop(err, "message") || S.stringify(err)
      true -> inspect(err)
    end
  end

  # Write the OBSERVABLE state of the live context back onto the ctx MAP omni
  # holds, which is where a retargeted `match: {ctx: ...}` assertion reads
  # (omni.ex decision 3). The live client and utility are dropped on the way
  # out: both reach back to this ctx, and the corpus never asserts on either.
  defp sync(node, ctx) do
    spec = S.getprop(ctx, "spec")
    if S.ismap(spec), do: S.setprop(node, "spec", spec)

    result = S.getprop(ctx, "result")
    if S.ismap(result), do: S.setprop(node, "result", neutral_result(result))

    response = S.getprop(ctx, "response")
    if S.ismap(response), do: S.setprop(node, "response", neutral_response(response))

    S.delprop(node, "client")
    S.delprop(node, "utility")
    node
  end

  # A result that IS a result node answers in the corpus's own spelling.
  defp neutralise(out) do
    if S.ismap(out) and S.getprop(out, "status_text") != nil, do: neutral_result(out), else: out
  end

  # --- the corpus ----------------------------------------------------------

  test "the primary corpus runs through the vendored omni engine", %{run: run, sdk: sdk} do
    O.reset_cases()

    spec = run.spec

    base = [sdk: sdk]

    # A ctx-style subject: materialise, run, publish the observable state.
    ctxrun = fn args, opts, fun ->
      node = argnode(args, 0)
      ctx = livectx(node, opts)
      out = unwrap(fun.(ctx))
      sync(node, ctx)
      out
    end

    # Look up one corpus section and drive it. The section name rides along as
    # omni's failure LABEL, so a failing entry names the section it came from
    # rather than the run.
    runsection = fn name, subject ->
      run.runsetflags.(section(spec, name), %{name: "primary.#{name}"}, subject)
    end

    runsection.("done", fn args -> ctxrun.(args, base, &U.done/1) end)

    # makeContext takes a PLAIN map and returns a context; it needs no client
    # and no utility dispatch. Handing it a live ctx would copy the client
    # through, and the walk back out would then follow client -> rootctx ->
    # client.
    runsection.("makeContext", fn args ->
      ctxmap = argnode(args, 0)
      out = Univec.Context.new(ctxmap, nil)
      S.delprop(out, "client")
      S.delprop(out, "utility")
      S.delprop(out, "config")
      S.delprop(out, "opmap")
      out
    end)

    runsection.("makeError", fn args ->
      node = argnode(args, 0)
      ctx = livectx(node, base)
      out = unwrap(U.make_error(ctx, Enum.at(args, 1)))
      sync(node, ctx)
      out
    end)

    runsection.("makeOptions", fn args ->
      vin = argnode(args, 0)
      ctx = livectx(S.jm([]), base)
      S.setprop(ctx, "config", S.getprop(vin, "config"))
      S.setprop(ctx, "options", S.getprop(vin, "options"))
      unwrap(U.make_options(ctx))
    end)

    runsection.("makeRequest", fn args -> ctxrun.(args, base, &U.make_request/1) end)
    runsection.("makeResponse", fn args -> ctxrun.(args, base, &U.make_response/1) end)

    # makeSpec and prepareAuth are configured by their OWN DEF.setup.a block,
    # not by the client's default options - the corpus supplies the base URL
    # and the api key the cases assert on. prepare_auth reads its options off
    # the CLIENT (as the reference does, via client.options()), so the section
    # gets a client built from the same block.
    specsdk = Univec.test(nil, setup_opts(spec, "makeSpec"))
    specopts = [sdk: specsdk, client: true]

    runsection.("makeSpec", fn args -> ctxrun.(args, specopts, &U.make_spec/1) end)

    runsection.("makeUrl", fn args -> ctxrun.(args, base, &U.make_url/1) end)

    runsection.("operator", fn args ->
      op = Univec.Operation.new(argnode(args, 0))

      S.jm([
        "entity", S.getprop(op, "entity"),
        "input", S.getprop(op, "input"),
        "name", S.getprop(op, "name"),
        "points", S.getprop(op, "points")
      ])
    end)

    runsection.("param", fn args ->
      node = argnode(args, 0)
      ctx = livectx(node, base)
      out = unwrap(U.param(ctx, Enum.at(args, 1)))
      sync(node, ctx)
      out
    end)

    authsdk = Univec.test(nil, setup_opts(spec, "prepareAuth"))
    authopts = [sdk: authsdk, client: true]

    runsection.("prepareAuth", fn args -> ctxrun.(args, authopts, &U.prepare_auth/1) end)
    runsection.("prepareBody", fn args -> ctxrun.(args, base, &U.prepare_body/1) end)

    runsection.("prepareHeaders", fn args ->
      ctxrun.(args, [sdk: sdk, client: true], &U.prepare_headers/1)
    end)

    runsection.("prepareMethod", fn args -> ctxrun.(args, base, &U.prepare_method/1) end)
    runsection.("prepareParams", fn args -> ctxrun.(args, base, &U.prepare_params/1) end)
    runsection.("preparePath", fn args -> ctxrun.(args, base, &U.prepare_path/1) end)
    runsection.("prepareQuery", fn args -> ctxrun.(args, base, &U.prepare_query/1) end)

    # A result-shaping section: the utility answers WITH the result node, which
    # is published in the corpus's own spelling on both the result and the ctx.
    resultrun = fn args, fun ->
      node = argnode(args, 0)
      ctx = livectx(node, base)
      out = unwrap(fun.(ctx))
      sync(node, ctx)
      neutralise(out)
    end

    runsection.("resultBasic", fn args -> resultrun.(args, &U.result_basic/1) end)
    runsection.("resultBody", fn args -> resultrun.(args, &U.result_body/1) end)
    runsection.("resultHeaders", fn args -> resultrun.(args, &U.result_headers/1) end)

    runsection.("transformRequest", fn args -> ctxrun.(args, base, &U.transform_request/1) end)
    runsection.("transformResponse", fn args -> ctxrun.(args, base, &U.transform_response/1) end)

    ran = O.cases()
    IO.puts("\nPRIMARY CORPUS: CASES #{ran} (vendored omni)")

    # A run that executes nothing is not a pass. A FLOOR, so the corpus can
    # grow without editing this line, and a section that stopped running
    # trips it.
    assert ran >= 67, "the primary corpus executed only #{ran} cases"
  end
end
