# Convert entity test (offline, mock transport)

defmodule Univec.ConvertEntityTest do
  use ExUnit.Case

  alias Voxgig.Struct, as: S
  alias Univec.Helpers, as: H
  alias Univec.Json

  defp fixture do
    Json.parse(File.read!("../.sdk/test/entity/convert/ConvertTestData.json"))
  end

  defp mk_sdk do
    existing = H.or_(S.getpath(fixture(), "existing"), S.jm([]))
    Univec.test(S.jm(["entity", existing]))
  end

  defp first_id do
    existing = H.or_(S.getpath(fixture(), "existing.convert"), S.jm([]))
    keys = S.keysof(existing)
    if keys == [], do: nil, else: hd(keys)
  end

  test "should create instance" do
    sdk = Univec.test()
    ent = Univec.convert(sdk)
    assert ent != nil
  end

  test "should create then read back" do
    sdk = Univec.test(S.jm(["entity", S.jm(["convert", S.jm([])])]))
    ent = Univec.convert(sdk)
    created = Univec.Entity.Convert.create(ent, S.jm(["name", "test-create"]))
    made = Univec.EntityBase.data_get(created)
    assert S.ismap(made)
    assert S.getprop(made, "id") != nil
  end
end
