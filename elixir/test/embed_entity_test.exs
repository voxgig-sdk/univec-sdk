# Embed entity test (offline, mock transport)

defmodule Univec.EmbedEntityTest do
  use ExUnit.Case

  alias Voxgig.Struct, as: S

  test "should create instance" do
    sdk = Univec.test()
    ent = Univec.embed(sdk)
    assert ent != nil
  end

  test "should create then read back" do
    sdk = Univec.test(S.jm(["entity", S.jm(["embed", S.jm([])])]))
    ent = Univec.embed(sdk)
    created = Univec.Entity.Embed.create(ent, S.jm(["name", "test-create"]))
    made = Univec.EntityBase.data_get(created)
    assert S.ismap(made)
    assert S.getprop(made, "id") != nil
  end

  test "should refuse an invalid request" do
    if Univec.FeatureHarness.has_feature("validate") do
      client = Univec.test(nil, S.jm(["feature", S.jm(["validate", S.jm(["active", true])])]))

      err =
        assert_raise Univec.Error, fn ->
          Univec.Entity.Embed.create(Univec.embed(client), S.jm(["embeddings", "x", "model", 1, "texts", "x"]))
        end

      assert err.code == "validate_failed"
    end
  end
end
