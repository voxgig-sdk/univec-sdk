
import {
  KIT,
  Model,
  ModelEntity,
  getModelPath,
} from '@voxgig/apidef'

import {
  Content,
  File,
  cmp,
  elixirAccessor,
  entityCollection,
  invalidRequest,
  opReachable,
} from '@voxgig/sdkgen'


// Emit a per-entity ExUnit test that drives the real op pipeline against the
// `test` feature's in-memory mock, seeded from the scaffolded fixture
// (../.sdk/test/entity/<Name>/<Name>TestData.json -> existing.<entity>).
const TestEntity = cmp(function TestEntity(props: any) {
  const { model }: { model: Model } = props.ctx$
  const target = props.target
  const entity: ModelEntity = props.entity

  const Name = model.const.Name
  const EName = entity.Name
  const ename = entity.name
  const accessor = elixirAccessor(entity, entityCollection(model))

  // Each test calls with only what it shows, so a bare call must reach a
  // route: an id for load, nothing for list, a name for create.
  const ops: any = entity.op || {}
  const hasLoad = opReachable(ops.load, ['id'])
  const hasList = opReachable(ops.list, [])
  const hasCreate = opReachable(ops.create, ['name'])

  const fixture = `../.sdk/test/entity/${ename}/${EName}TestData.json`
  const bad = invalidRequest(entity)

  // Only what the emitted tests call: elixir warns on an unused alias or
  // private function.
  const seeded = hasList || hasLoad
  const head = [
    ...(seeded || hasCreate || null != bad ? ['  alias Voxgig.Struct, as: S'] : []),
    ...(seeded ? [`  alias ${Name}.Helpers, as: H`, `  alias ${Name}.Json`, `
  defp fixture do
    Json.parse(File.read!(${JSON.stringify(fixture)}))
  end

  defp mk_sdk do
    existing = H.or_(S.getpath(fixture(), "existing"), S.jm([]))
    ${Name}.test(S.jm(["entity", existing]))
  end`] : []),
    ...(hasLoad ? [`
  defp first_id do
    existing = H.or_(S.getpath(fixture(), "existing.${ename}"), S.jm([]))
    keys = S.keysof(existing)
    if keys == [], do: nil, else: hd(keys)
  end`] : []),
  ]

  File({ name: ename + '_entity_test.exs' }, () => {

    Content(`# ${EName} entity test (offline, mock transport)

defmodule ${Name}.${EName}EntityTest do
  use ExUnit.Case
${0 < head.length ? '\n' + head.join('\n') + '\n' : ''}
  test "should create instance" do
    sdk = ${Name}.test()
    ent = ${Name}.${accessor}(sdk)
    assert ent != nil
  end
`)

    if (hasList) {
      Content(`
  test "should list records" do
    sdk = mk_sdk()
    ent = ${Name}.${accessor}(sdk)
    # The op resolves to one ENTITY per record; the record is reached with
    # data_get. See AGENTS.md "Entity operations return ENTITIES".
    result = ${Name}.Entity.${EName}.list(ent, S.jm([]))
    assert S.islist(result)
    if S.size(result) > 0 do
      Enum.each(0..(S.size(result) - 1), fn i ->
        assert S.ismap(${Name}.EntityBase.data_get(S.getelem(result, i)))
      end)
    end
  end
`)
    }

    if (hasLoad) {
      Content(`
  test "should load an existing record" do
    id = first_id()

    if id != nil do
      sdk = mk_sdk()
      ent = ${Name}.${accessor}(sdk)
      loaded = ${Name}.Entity.${EName}.load(ent, S.jm(["id", id]))
      rec = ${Name}.EntityBase.data_get(loaded)
      assert S.ismap(rec)
      assert S.getprop(rec, "id") == id
    end
  end
`)
    }

    if (hasCreate) {
      Content(`
  test "should create then read back" do
    sdk = ${Name}.test(S.jm(["entity", S.jm(["${ename}", S.jm([])])]))
    ent = ${Name}.${accessor}(sdk)
    created = ${Name}.Entity.${EName}.create(ent, S.jm(["name", "test-create"]))
    made = ${Name}.EntityBase.data_get(created)
    assert S.ismap(made)
    assert S.getprop(made, "id") != nil
  end
`)
    }

    if (hasList) {
      Content(`
  test "should report a failed stream" do
    offline = S.jm(["net", S.jm(["offline", true])])

    err =
      assert_raise ${Name}.Error, fn ->
        Enum.to_list(${Name}.EntityBase.stream(${Name}.${accessor}(${Name}.test(offline)), "list"))
      end

    assert String.contains?(Exception.message(err), "offline")

    quiet = S.jm(["ctrl", S.jm(["throw", false])])
    Enum.to_list(${Name}.EntityBase.stream(${Name}.${accessor}(${Name}.test(offline)), "list", nil, quiet))

    if ${Name}.FeatureHarness.has_feature("rbac") do
      denied = ${Name}.test(nil, S.jm(["feature", S.jm(["rbac", S.jm(["active", true, "deny", true])])]))

      err =
        assert_raise ${Name}.Error, fn ->
          Enum.to_list(${Name}.EntityBase.stream(${Name}.${accessor}(denied), "list"))
        end

      assert err.code == "rbac_denied"
    end
  end

  test "should leave the caller's ctrl" do
    explain = S.jm([])
    ctrl = S.jm(["explain", explain])
    Enum.to_list(${Name}.EntityBase.stream(${Name}.${accessor}(${Name}.test()), "list", nil, S.jm(["ctrl", ctrl])))
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
            fn -> Stream.map([1], fn _ -> raise "${ename} source failed" end) end)
        end,
        "PreUnexpected", fn _ctx -> S.setprop(seen, "n", S.getprop(seen, "n") + 1) end
      ])

    client = ${Name}.new(S.jm(["feature", S.jm(["test", S.jm(["active", true])]), "extend", S.jt([hook])]))

    err =
      try do
        Enum.to_list(${Name}.EntityBase.stream(${Name}.${accessor}(client), "list"))
        nil
      rescue
        e -> e
      end

    assert err != nil and String.contains?(Exception.message(err), "source failed")
    assert S.getprop(seen, "n") > 0

    fired = S.getprop(seen, "n")
    quiet = S.jm(["ctrl", S.jm(["throw", false])])
    assert Enum.to_list(${Name}.EntityBase.stream(${Name}.${accessor}(client), "list", nil, quiet)) == []
    assert S.getprop(seen, "n") > fired
  end

  test "should fire PreUnexpected" do
    seen = S.jm(["n", 0])

    hook =
      S.jm([
        "name", "failhook", "version", "0.0.1", "active", true, "options", S.jm([]),
        "init", fn _ctx, _opts -> nil end,
        "PreSpec", fn _ctx -> raise "${ename} hook failed" end,
        "PreUnexpected", fn _ctx -> S.setprop(seen, "n", S.getprop(seen, "n") + 1) end
      ])

    client = ${Name}.new(S.jm(["feature", S.jm(["test", S.jm(["active", true])]), "extend", S.jt([hook])]))

    err =
      try do
        ${Name}.Entity.${EName}.list(${Name}.${accessor}(client), S.jm([]))
        nil
      rescue
        e -> e
      end

    assert err != nil and String.contains?(Exception.message(err), "hook failed")
    assert S.getprop(seen, "n") > 0

    fired = S.getprop(seen, "n")
    assert ${Name}.Entity.${EName}.list(${Name}.${accessor}(client), S.jm([]), S.jm(["throw", false])) == nil
    assert S.getprop(seen, "n") > fired
  end
`)
    }

    if (null != bad) {
      const args = Object.entries(bad.args)
        .map(([k, v]) => JSON.stringify(k) + ', ' + JSON.stringify(v)).join(', ')
      Content(`
  test "should refuse an invalid request" do
    if ${Name}.FeatureHarness.has_feature("validate") do
      client = ${Name}.test(nil, S.jm(["feature", S.jm(["validate", S.jm(["active", true])])]))

      err =
        assert_raise ${Name}.Error, fn ->
          ${Name}.Entity.${EName}.${bad.op}(${Name}.${accessor}(client), S.jm([${args}]))
        end

      assert err.code == "validate_failed"
    end
  end
`)
    }

    Content(`end
`)
  })
})


export {
  TestEntity
}
