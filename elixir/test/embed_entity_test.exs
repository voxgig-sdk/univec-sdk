# Embed entity test (offline, mock transport)

defmodule Univec.EmbedEntityTest do
  use ExUnit.Case

  alias Voxgig.Struct, as: S
  alias Univec.Helpers, as: H
  alias Univec.Json

  defp fixture do
    Json.parse(File.read!("../.sdk/test/entity/embed/EmbedTestData.json"))
  end

  defp mk_sdk do
    existing = H.or_(S.getpath(fixture(), "existing"), S.jm([]))
    Univec.test(S.jm(["entity", existing]))
  end

  defp first_id do
    existing = H.or_(S.getpath(fixture(), "existing.embed"), S.jm([]))
    keys = S.keysof(existing)
    if keys == [], do: nil, else: hd(keys)
  end

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
end
