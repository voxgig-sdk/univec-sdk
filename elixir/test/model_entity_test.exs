# Model entity test (offline, mock transport)

defmodule Univec.ModelEntityTest do
  use ExUnit.Case

  alias Voxgig.Struct, as: S
  alias Univec.Helpers, as: H
  alias Univec.Json

  defp fixture do
    Json.parse(File.read!("../.sdk/test/entity/model/ModelTestData.json"))
  end

  defp mk_sdk do
    existing = H.or_(S.getpath(fixture(), "existing"), S.jm([]))
    Univec.test(S.jm(["entity", existing]))
  end

  test "should create instance" do
    sdk = Univec.test()
    ent = Univec.model(sdk)
    assert ent != nil
  end

  test "should list records" do
    sdk = mk_sdk()
    ent = Univec.model(sdk)
    # The op resolves to one ENTITY per record; the record is reached with
    # data_get. See AGENTS.md "Entity operations return ENTITIES".
    result = Univec.Entity.Model.list(ent, S.jm([]))
    assert S.islist(result)
    if S.size(result) > 0 do
      Enum.each(0..(S.size(result) - 1), fn i ->
        assert S.ismap(Univec.EntityBase.data_get(S.getelem(result, i)))
      end)
    end
  end

  test "should report a failed stream" do
    offline = S.jm(["net", S.jm(["offline", true])])

    err =
      assert_raise Univec.Error, fn ->
        Enum.to_list(Univec.EntityBase.stream(Univec.model(Univec.test(offline)), "list"))
      end

    assert String.contains?(Exception.message(err), "offline")

    quiet = S.jm(["ctrl", S.jm(["throw", false])])
    Enum.to_list(Univec.EntityBase.stream(Univec.model(Univec.test(offline)), "list", nil, quiet))

    if Univec.FeatureHarness.has_feature("rbac") do
      denied = Univec.test(nil, S.jm(["feature", S.jm(["rbac", S.jm(["active", true, "deny", true])])]))

      err =
        assert_raise Univec.Error, fn ->
          Enum.to_list(Univec.EntityBase.stream(Univec.model(denied), "list"))
        end

      assert err.code == "rbac_denied"
    end
  end

  test "should leave the caller's ctrl" do
    explain = S.jm([])
    ctrl = S.jm(["explain", explain])
    Enum.to_list(Univec.EntityBase.stream(Univec.model(Univec.test()), "list", nil, S.jm(["ctrl", ctrl])))
    assert S.keysof(ctrl) == ["explain"]
    assert S.size(explain) > 0
  end

  test "should end a stream whose source fails as the operation would" do
    seen = S.jm(["n", 0])

    hook =
      S.jm([
        "name", "lazyhook", "version", "0.0.1", "active", true, "options", S.jm([]),
        "init", fn _ctx, _opts -> nil end,
        "PreDone", fn ctx ->
          S.setprop(S.getprop(ctx, "result"), "stream",
            fn -> Stream.map([1], fn _ -> raise "model source failed" end) end)
        end,
        "PreUnexpected", fn _ctx -> S.setprop(seen, "n", S.getprop(seen, "n") + 1) end
      ])

    client = Univec.new(S.jm(["feature", S.jm(["test", S.jm(["active", true])]), "extend", S.jt([hook])]))

    err =
      try do
        Enum.to_list(Univec.EntityBase.stream(Univec.model(client), "list"))
        nil
      rescue
        e -> e
      end

    assert err != nil and String.contains?(Exception.message(err), "source failed")
    assert S.getprop(seen, "n") > 0

    fired = S.getprop(seen, "n")
    quiet = S.jm(["ctrl", S.jm(["throw", false])])
    assert Enum.to_list(Univec.EntityBase.stream(Univec.model(client), "list", nil, quiet)) == []
    assert S.getprop(seen, "n") > fired
  end

  test "should fire PreUnexpected" do
    seen = S.jm(["n", 0])

    hook =
      S.jm([
        "name", "failhook", "version", "0.0.1", "active", true, "options", S.jm([]),
        "init", fn _ctx, _opts -> nil end,
        "PreSpec", fn _ctx -> raise "model hook failed" end,
        "PreUnexpected", fn _ctx -> S.setprop(seen, "n", S.getprop(seen, "n") + 1) end
      ])

    client = Univec.new(S.jm(["feature", S.jm(["test", S.jm(["active", true])]), "extend", S.jt([hook])]))

    err =
      try do
        Univec.Entity.Model.list(Univec.model(client), S.jm([]))
        nil
      rescue
        e -> e
      end

    assert err != nil and String.contains?(Exception.message(err), "hook failed")
    assert S.getprop(seen, "n") > 0

    fired = S.getprop(seen, "n")
    assert Univec.Entity.Model.list(Univec.model(client), S.jm([]), S.jm(["throw", false])) == nil
    assert S.getprop(seen, "n") > fired
  end

  test "should refuse an invalid request" do
    if Univec.FeatureHarness.has_feature("validate") do
      client = Univec.test(nil, S.jm(["feature", S.jm(["validate", S.jm(["active", true])])]))

      err =
        assert_raise Univec.Error, fn ->
          Univec.Entity.Model.list(Univec.model(client), S.jm(["executionProvider", 1]))
        end

      assert err.code == "validate_failed"
    end
  end
end
