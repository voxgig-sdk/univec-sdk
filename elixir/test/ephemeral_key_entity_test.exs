# EphemeralKey entity test (offline, mock transport)

defmodule Univec.EphemeralKeyEntityTest do
  use ExUnit.Case

  alias Voxgig.Struct, as: S

  test "should create instance" do
    sdk = Univec.test()
    ent = Univec.ephemeral_key(sdk)
    assert ent != nil
  end

  test "should create then read back" do
    sdk = Univec.test(S.jm(["entity", S.jm(["ephemeral_key", S.jm([])])]))
    ent = Univec.ephemeral_key(sdk)
    created = Univec.Entity.EphemeralKey.create(ent, S.jm(["name", "test-create"]))
    made = Univec.EntityBase.data_get(created)
    assert S.ismap(made)
    assert S.getprop(made, "id") != nil
  end

  test "should refuse an invalid request" do
    if Univec.FeatureHarness.has_feature("validate") do
      client = Univec.test(nil, S.jm(["feature", S.jm(["validate", S.jm(["active", true])])]))

      err =
        assert_raise Univec.Error, fn ->
          Univec.Entity.EphemeralKey.create(Univec.ephemeral_key(client), S.jm(["dailyLimit", "x", "dailyUsed", 1, "key", "x", "resetsAt", "x"]))
        end

      assert err.code == "validate_failed"
    end
  end
end
