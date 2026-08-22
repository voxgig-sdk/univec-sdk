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

  defp first_id do
    existing = H.or_(S.getpath(fixture(), "existing.model"), S.jm([]))
    keys = S.keysof(existing)
    if keys == [], do: nil, else: hd(keys)
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
end
