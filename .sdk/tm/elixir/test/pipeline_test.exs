# Univec SDK pipeline test
#
# Direct unit tests for the operation-pipeline utilities. The generated entity
# tests exercise the happy path; these drive the error and edge branches
# (missing spec/response/result, 4xx handling, transport failures, feature
# ordering, auth header shaping) that a normal success-path op never reaches.
# All utilities are reached through the client's utility view, so this suite is
# API-agnostic.

# A fake entity module for the make_result list-wrapping test: make/1 spawns a
# record carrying the shared collector, data_set/2 pushes each entry onto it.
defmodule Univec.PipelineFakeEntity do
  alias Voxgig.Struct, as: S

  def make(entity), do: S.jm(["_collector", S.getprop(entity, "_collector")])

  def data_set(rec, entry) do
    col = S.getprop(rec, "_collector")
    S.setprop(col, S.size(col), entry)
    rec
  end
end

defmodule Univec.PipelineTest do
  use ExUnit.Case

  alias Voxgig.Struct, as: S
  alias Univec.Helpers, as: H
  alias Univec.{Utility, Context, Spec, Result, Response}

  defp client, do: Univec.test()

  defp make_ctx(client, opname \\ "load") do
    Context.new(S.jm(["opname", opname, "ctrl", S.jm([])]), Univec.get_root_ctx(client))
  end

  # Transport-shaped response node with a re-readable body + lowercase headers.
  defp resp(status, data \\ nil, headers \\ nil) do
    h = S.jm([])

    if headers != nil do
      Enum.each(H.entries(headers), fn {k, v} -> S.setprop(h, String.downcase(to_string(k)), v) end)
    end

    Response.new(
      S.jm([
        "status", status,
        "statusText", if(status < 400, do: "OK", else: "ERR"),
        "body", "body",
        "json", fn -> data end,
        "headers", h
      ])
    )
  end

  defp spec_of(map \\ %{}) do
    Spec.new(H.deep(Map.merge(%{"step" => "s", "method" => "GET", "headers" => %{}}, map)))
  end

  defp request_spec, do: spec_of(%{"base" => "http://h", "path" => "a"})

  # Override the client utility's fetcher (or another member) in place.
  defp util_override(c, key, fun) do
    S.setprop(Univec.get_utility(c), key, fun)
    c
  end

  # === feature order (PR review #2) ===

  # make_options resolves the feature add-order into __derived__.featureorder:
  # a map defaults test-first (so the test mock is the base transport), an
  # explicit array preserves the developer order, and a map without test is
  # deterministic (names sorted).
  defp resolve_order(feature) do
    ctx = Context.new(S.jm(["opname", "load", "ctrl", S.jm([])]), Univec.get_root_ctx(client()))
    S.setprop(ctx, "options", S.jm(["feature", feature]))
    S.setprop(ctx, "config", S.jm(["options", S.jm([])]))
    Utility.make_options(ctx)
  end

  defp order_list(opts) do
    fo = S.getpath(opts, "__derived__.featureorder")
    if S.islist(fo), do: Enum.map(0..(S.size(fo) - 1), fn i -> S.getelem(fo, i) end), else: []
  end

  test "feature order: map form is ordered test-first" do
    o = resolve_order(S.jm(["metrics", S.jm(["active", true]), "test", S.jm(["active", true])]))
    assert order_list(o) == ["test", "metrics"]
  end

  test "feature order: array form preserves the explicit developer order" do
    o = resolve_order(S.jt([S.jm(["name", "metrics", "active", true]), S.jm(["name", "test", "active", true])]))
    assert order_list(o) == ["metrics", "test"]
    assert S.getpath(o, "feature.metrics.active") == true
    assert S.getpath(o, "feature.test.active") == true
  end

  test "feature order: map form with no test orders names deterministically" do
    o = resolve_order(S.jm(["retry", S.jm(["active", true]), "cache", S.jm(["active", true])]))
    assert order_list(o) == ["cache", "retry"]
  end

  # === make_point ===

  test "make_point rejects a disallowed operation" do
    ctx = make_ctx(client(), "nope")
    {_out, err} = Utility.make_point(ctx)
    assert err.code == "point_op_allow"
  end

  test "make_point rejects an operation with no endpoints" do
    ctx = make_ctx(client())
    S.setprop(S.getprop(ctx, "op"), "points", S.jt([]))
    {_out, err} = Utility.make_point(ctx)
    assert err.code == "point_no_points"
  end

  test "make_point returns the single point" do
    ctx = make_ctx(client())
    point = H.deep(%{"parts" => ["a"], "args" => %{"params" => []}})
    S.setprop(S.getprop(ctx, "op"), "points", S.jt([point]))
    {out, err} = Utility.make_point(ctx)
    assert err == nil
    assert out == point
  end

  test "make_point short circuits a feature supplied point" do
    ctx = make_ctx(client())
    preset = H.deep(%{"parts" => ["a"]})
    S.setprop(S.getprop(ctx, "out"), "point", preset)
    {out, err} = Utility.make_point(ctx)
    assert err == nil
    assert out == preset
  end

  test "make_point surfaces a feature supplied error" do
    ctx = make_ctx(client())
    denial = Context.make_error(ctx, "rbac_denied", "denied")
    S.setprop(S.getprop(ctx, "out"), "point", denial)
    {out, err} = Utility.make_point(ctx)
    assert out == nil
    assert err.code == "rbac_denied"
  end

  # === make_spec ===

  test "make_spec short circuits a feature supplied spec" do
    ctx = make_ctx(client())
    preset = spec_of(%{"method" => "GET"})
    S.setprop(S.getprop(ctx, "out"), "spec", preset)
    {out, err} = Utility.make_spec(ctx)
    assert err == nil
    assert out == preset
  end

  # === make_response ===

  test "make_response guards missing spec, response, result" do
    c = client()

    ctx = make_ctx(c)
    S.setprop(ctx, "spec", nil)
    S.setprop(ctx, "response", resp(200))
    S.setprop(ctx, "result", Result.new(nil))
    {_o, err} = Utility.make_response(ctx)
    assert err.code == "response_no_spec"

    ctx = make_ctx(c)
    S.setprop(ctx, "spec", spec_of())
    S.setprop(ctx, "response", nil)
    S.setprop(ctx, "result", Result.new(nil))
    {_o, err} = Utility.make_response(ctx)
    assert err.code == "response_no_response"

    ctx = make_ctx(c)
    S.setprop(ctx, "spec", spec_of())
    S.setprop(ctx, "response", resp(200))
    S.setprop(ctx, "result", nil)
    {_o, err} = Utility.make_response(ctx)
    assert err.code == "response_no_result"
  end

  test "make_response 4xx sets result err and copies headers" do
    ctx = make_ctx(client())
    S.setprop(ctx, "spec", spec_of())
    S.setprop(ctx, "response", resp(404, nil, H.deep(%{"x-a" => "1"})))
    S.setprop(ctx, "result", Result.new(nil))
    {_o, err} = Utility.make_response(ctx)
    assert err == nil
    result = S.getprop(ctx, "result")
    assert S.getprop(result, "err") != nil
    assert S.getprop(result, "status") == 404
    assert S.getprop(S.getprop(result, "headers"), "x-a") == "1"
    assert S.getprop(result, "ok") == false
  end

  test "make_response 2xx parses the body and marks ok" do
    ctx = make_ctx(client())
    S.setprop(ctx, "spec", spec_of())
    S.setprop(ctx, "response", resp(200, H.deep(%{"v" => 1})))
    S.setprop(ctx, "result", Result.new(nil))
    {_o, err} = Utility.make_response(ctx)
    assert err == nil
    result = S.getprop(ctx, "result")
    assert S.getprop(result, "ok") == true
    assert S.getprop(S.getprop(result, "body"), "v") == 1
  end

  test "make_response records to ctrl explain" do
    ctx = make_ctx(client())
    S.setprop(S.getprop(ctx, "ctrl"), "explain", S.jm([]))
    S.setprop(ctx, "spec", spec_of())
    S.setprop(ctx, "response", resp(200, H.deep(%{"v" => 2})))
    S.setprop(ctx, "result", Result.new(nil))
    Utility.make_response(ctx)
    assert S.getprop(S.getprop(S.getprop(ctx, "ctrl"), "explain"), "result") != nil
  end

  test "make_response short circuits a feature supplied response" do
    ctx = make_ctx(client())
    preset = resp(299)
    S.setprop(S.getprop(ctx, "out"), "response", preset)
    S.setprop(ctx, "spec", spec_of())
    S.setprop(ctx, "response", resp(200))
    S.setprop(ctx, "result", Result.new(nil))
    {out, err} = Utility.make_response(ctx)
    assert err == nil
    assert out == preset
  end

  # === make_result ===

  test "make_result guards missing spec and result" do
    c = client()

    ctx = make_ctx(c)
    S.setprop(ctx, "spec", nil)
    S.setprop(ctx, "result", Result.new(nil))
    {_o, err} = Utility.make_result(ctx)
    assert err.code == "result_no_spec"

    ctx = make_ctx(c)
    S.setprop(ctx, "spec", spec_of())
    S.setprop(ctx, "result", nil)
    {_o, err} = Utility.make_result(ctx)
    assert err.code == "result_no_result"
  end

  defp list_ctx(c, collector) do
    entity =
      S.jm(["_module", Univec.PipelineFakeEntity, "_name", "widget", "_collector", collector])

    Context.new(S.jm(["opname", "list", "entity", entity, "ctrl", S.jm([])]), Univec.get_root_ctx(c))
  end

  test "make_result list op wraps resdata into entities" do
    collector = S.jt([])
    ctx = list_ctx(client(), collector)
    S.setprop(ctx, "spec", spec_of())
    S.setprop(ctx, "result", Result.new(H.deep(%{"ok" => true, "resdata" => [%{"a" => 1}, %{"a" => 2}]})))
    {result, err} = Utility.make_result(ctx)
    assert err == nil
    assert S.size(S.getprop(result, "resdata")) == 2
    assert S.size(collector) == 2
    assert S.getprop(S.getelem(collector, 0), "a") == 1
    assert S.getprop(S.getelem(collector, 1), "a") == 2
  end

  test "make_result empty list yields an empty resdata array" do
    collector = S.jt([])
    ctx = list_ctx(client(), collector)
    S.setprop(ctx, "spec", spec_of())
    S.setprop(ctx, "result", Result.new(H.deep(%{"ok" => true, "resdata" => []})))
    {result, err} = Utility.make_result(ctx)
    assert err == nil
    rd = S.getprop(result, "resdata")
    assert S.islist(rd)
    assert S.size(rd) == 0
  end

  test "make_result short circuits a preset result" do
    ctx = make_ctx(client())
    preset = Result.new(H.deep(%{"ok" => true}))
    S.setprop(S.getprop(ctx, "out"), "result", preset)
    {out, err} = Utility.make_result(ctx)
    assert err == nil
    assert out == preset
  end

  # === make_request ===

  test "make_request guards a missing spec" do
    ctx = make_ctx(client())
    S.setprop(ctx, "spec", nil)
    {_o, err} = Utility.make_request(ctx)
    assert err.code == "request_no_spec"
  end

  test "make_request a transport error tuple lands on the response" do
    boom = Univec.Error.new("boom", "boom")
    c = util_override(client(), "fetcher", fn _c, _u, _f -> {nil, boom} end)
    ctx = make_ctx(c)
    S.setprop(ctx, "spec", request_spec())
    {response, err} = Utility.make_request(ctx)
    assert err == nil
    assert S.getprop(response, "err").code == "boom"
  end

  test "make_request a nil transport result becomes a response error" do
    c = util_override(client(), "fetcher", fn _c, _u, _f -> {nil, nil} end)
    ctx = make_ctx(c)
    S.setprop(ctx, "spec", request_spec())
    {response, err} = Utility.make_request(ctx)
    assert err == nil
    assert S.getprop(response, "err") != nil
  end

  test "make_request wraps a normal transport response" do
    c =
      util_override(client(), "fetcher", fn _c, _u, _f ->
        {S.jm(["status", 200, "statusText", "OK", "headers", S.jm([]), "json", fn -> H.deep(%{"a" => 1}) end, "body", "b"]),
         nil}
      end)

    ctx = make_ctx(c)
    S.setprop(ctx, "spec", request_spec())
    {response, err} = Utility.make_request(ctx)
    assert err == nil
    assert S.getprop(response, "status") == 200
  end

  test "make_request records the fetchdef to ctrl explain" do
    c =
      util_override(client(), "fetcher", fn _c, _u, _f ->
        {S.jm(["status", 200, "statusText", "OK", "headers", S.jm([]), "json", fn -> nil end, "body", "b"]), nil}
      end)

    ctx = make_ctx(c)
    S.setprop(S.getprop(ctx, "ctrl"), "explain", S.jm([]))
    S.setprop(ctx, "spec", request_spec())
    Utility.make_request(ctx)
    assert S.getprop(S.getprop(S.getprop(ctx, "ctrl"), "explain"), "fetchdef") != nil
  end

  test "make_request a fetchdef error surfaces as a response error" do
    c = util_override(client(), "make_fetch_def", fn _ctx -> {nil, Univec.Error.new("fetchdef_boom", "boom")} end)
    ctx = make_ctx(c)
    S.setprop(ctx, "spec", request_spec())
    {response, err} = Utility.make_request(ctx)
    assert err == nil
    assert S.getprop(response, "err") != nil
    assert S.getprop(response, "err").code == "fetchdef_boom"
  end

  test "make_request short circuits a feature supplied request" do
    ctx = make_ctx(client())
    preset = resp(201)
    S.setprop(S.getprop(ctx, "out"), "request", preset)
    S.setprop(ctx, "spec", request_spec())
    {out, err} = Utility.make_request(ctx)
    assert err == nil
    assert out == preset
  end

  # === make_fetch_def ===

  test "make_fetch_def guards a missing spec" do
    ctx = make_ctx(client())
    S.setprop(ctx, "spec", nil)
    {_o, err} = Utility.make_fetch_def(ctx)
    assert err.code == "fetchdef_no_spec"
  end

  test "make_fetch_def serialises a hash body and inits a missing result" do
    ctx = make_ctx(client())
    S.setprop(ctx, "result", nil)
    S.setprop(ctx, "spec", spec_of(%{"method" => "POST", "base" => "http://h", "path" => "a", "body" => %{"x" => 1}}))
    {fetchdef, err} = Utility.make_fetch_def(ctx)
    assert err == nil
    assert is_binary(S.getprop(fetchdef, "body"))
    assert String.contains?(S.getprop(fetchdef, "url"), "http://h")
    assert S.getprop(ctx, "result") != nil
  end

  # === make_error + done ===

  test "done returns resdata on success" do
    ctx = make_ctx(client())
    S.setprop(ctx, "result", Result.new(H.deep(%{"ok" => true, "resdata" => 42})))
    assert Utility.done(ctx) == 42
  end

  test "done raises the error when not ok" do
    ctx = make_ctx(client())
    S.setprop(ctx, "result", Result.new(H.deep(%{"ok" => false})))
    assert_raise Univec.Error, fn -> Utility.done(ctx) end
  end

  test "done cleans ctrl explain on success" do
    ctx = make_ctx(client())
    S.setprop(S.getprop(ctx, "ctrl"), "explain", H.deep(%{"result" => %{"err" => "x"}}))
    S.setprop(ctx, "result", Result.new(H.deep(%{"ok" => true, "resdata" => 7})))
    assert Utility.done(ctx) == 7
  end

  test "make_error returns resdata when throw is disabled" do
    ctx = make_ctx(client())
    S.setprop(S.getprop(ctx, "ctrl"), "throw_err", false)
    S.setprop(ctx, "result", Result.new(H.deep(%{"ok" => false, "resdata" => "fallback"})))
    assert Utility.make_error(ctx, nil) == "fallback"
  end

  test "make_error records to ctrl explain" do
    ctx = make_ctx(client())
    S.setprop(S.getprop(ctx, "ctrl"), "throw_err", false)
    S.setprop(S.getprop(ctx, "ctrl"), "explain", S.jm([]))
    S.setprop(ctx, "result", Result.new(H.deep(%{"ok" => false})))
    Utility.make_error(ctx, nil)
    assert S.getprop(S.getprop(S.getprop(ctx, "ctrl"), "explain"), "err") != nil
  end

  test "make_error preserves the error code" do
    ctx = make_ctx(client())

    err =
      assert_raise Univec.Error, fn ->
        Utility.make_error(ctx, Context.make_error(ctx, "rbac_denied", "denied"))
      end

    assert err.code == "rbac_denied"
  end

  # === feature ordering ===

  test "feature_add appends in call order" do
    c = client()
    ctx = make_ctx(c)
    S.setprop(c, "features", [])
    a = Univec.Feature.new()
    b = Univec.Feature.new()
    Utility.feature_add(ctx, a)
    Utility.feature_add(ctx, b)
    assert S.getprop(c, "features") == [a, b]
  end

  defp named_feature(name) do
    f = Univec.Feature.new()
    S.setprop(f, "name", name)
    f
  end

  defp feature_names(c), do: Enum.map(S.getprop(c, "features"), fn f -> S.getprop(f, "name") end)

  test "feature_add ordering before after replace" do
    c = client()
    ctx = make_ctx(c)
    S.setprop(c, "features", [])

    Utility.feature_add(ctx, named_feature("a"))
    Utility.feature_add(ctx, named_feature("b"))
    assert feature_names(c) == ["a", "b"]

    before = named_feature("z1")
    S.setprop(before, "_options", H.deep(%{"__before__" => "b"}))
    Utility.feature_add(ctx, before)
    assert feature_names(c) == ["a", "z1", "b"]

    after_ = named_feature("z2")
    S.setprop(after_, "_options", H.deep(%{"__after__" => "a"}))
    Utility.feature_add(ctx, after_)
    assert feature_names(c) == ["a", "z2", "z1", "b"]

    replace = named_feature("z3")
    S.setprop(replace, "_options", H.deep(%{"__replace__" => "z1"}))
    Utility.feature_add(ctx, replace)
    assert feature_names(c) == ["a", "z2", "z3", "b"]

    miss = named_feature("z4")
    S.setprop(miss, "_options", H.deep(%{"__before__" => "missing"}))
    Utility.feature_add(ctx, miss)
    assert feature_names(c) == ["a", "z2", "z3", "b", "z4"]
  end

  # === prepare_auth ===

  defp auth_ctx(c, options, headers) do
    fakeclient = S.jm(["options", H.deep(options)])

    ctx =
      Context.new(
        S.jm(["opname", "load", "client", fakeclient, "utility", Univec.get_utility(c), "ctrl", S.jm([])]),
        nil
      )

    spec = if headers == nil, do: nil, else: Spec.new(H.deep(%{"headers" => headers, "step" => "s"}))
    S.setprop(ctx, "spec", spec)
    ctx
  end

  defp auth_header(ctx), do: S.getprop(S.getprop(S.getprop(ctx, "spec"), "headers"), "authorization")

  test "prepare_auth guards a missing spec" do
    ctx = auth_ctx(client(), %{"auth" => %{"prefix" => ""}, "apikey" => "K"}, nil)
    {_o, err} = Utility.prepare_auth(ctx)
    assert err.code == "auth_no_spec"
  end

  test "prepare_auth an apikey with a prefix is space joined" do
    ctx = auth_ctx(client(), %{"apikey" => "K", "auth" => %{"prefix" => "Bearer"}}, %{})
    {_o, err} = Utility.prepare_auth(ctx)
    assert err == nil
    assert auth_header(ctx) == "Bearer K"
  end

  test "prepare_auth a raw apikey goes in as is" do
    ctx = auth_ctx(client(), %{"apikey" => "K", "auth" => %{"prefix" => ""}}, %{})
    Utility.prepare_auth(ctx)
    assert auth_header(ctx) == "K"
  end

  test "prepare_auth an empty apikey drops the header" do
    ctx = auth_ctx(client(), %{"apikey" => "", "auth" => %{"prefix" => "Bearer"}}, %{"authorization" => "stale"})
    Utility.prepare_auth(ctx)
    assert auth_header(ctx) == nil
  end

  test "prepare_auth a public api drops the header" do
    ctx = auth_ctx(client(), %{"apikey" => "K"}, %{"authorization" => "stale"})
    Utility.prepare_auth(ctx)
    assert auth_header(ctx) == nil
  end

  test "prepare_auth a missing apikey option drops the header" do
    ctx = auth_ctx(client(), %{"auth" => %{"prefix" => "Bearer"}}, %{"authorization" => "stale"})
    Utility.prepare_auth(ctx)
    assert auth_header(ctx) == nil
  end

  # === result helpers ===

  test "result_headers with non-map headers yields an empty map" do
    ctx = make_ctx(client())
    S.setprop(ctx, "response", Response.new(S.jm(["status", 200])))
    S.setprop(ctx, "result", Result.new(nil))
    Utility.result_headers(ctx)
    hdrs = S.getprop(S.getprop(ctx, "result"), "headers")
    assert S.ismap(hdrs)
    assert S.size(hdrs) == 0
  end

  test "result_body skips parsing when the body is absent" do
    ctx = make_ctx(client())
    S.setprop(ctx, "response", Response.new(S.jm(["status", 200, "json", fn -> H.deep(%{"a" => 1}) end, "body", nil])))
    S.setprop(ctx, "result", Result.new(nil))
    Utility.result_body(ctx)
    assert S.getprop(S.getprop(ctx, "result"), "body") == nil
  end
end
