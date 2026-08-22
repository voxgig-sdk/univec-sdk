
import {
  Model,
  ModelEntity,
} from '@voxgig/apidef'

import {
  Content,
  File,
  cmp,
} from '@voxgig/sdkgen'


// Emit a per-entity direct() test: a live-mode SDK wired to a recording
// mock system.fetch, exercising the raw-HTTP escape hatch.
const TestDirect = cmp(function TestDirect(props: any) {
  const { model }: { model: Model } = props.ctx$
  const target = props.target
  const entity: ModelEntity = props.entity

  const Name = model.const.Name
  const EName = entity.Name
  const ename = entity.name

  const opnames = Object.keys(entity.op || {})
  const hasLoad = opnames.includes('load')
  const hasList = opnames.includes('list')

  if (!hasLoad && !hasList) {
    return
  }

  File({ name: ename + '_direct_test.exs' }, () => {

    Content(`# ${EName} direct test (offline, mock system.fetch)

defmodule ${Name}.${EName}DirectTest do
  use ExUnit.Case

  alias Voxgig.Struct, as: S
  alias ${Name}.Helpers, as: H

  # A recording live-mode SDK whose transport returns \`canned\`.
  defp mk(canned) do
    parent = self()

    fetch = fn url, _fetchdef ->
      send(parent, {:called, url})
      {S.jm(["status", 200, "statusText", "OK", "headers", S.jm([]), "json", fn -> canned end, "body", "mock"]), nil}
    end

    ${Name}.new(S.jm(["base", "http://localhost:8080", "system", S.jm(["fetch", fetch])]))
  end
`)

    if (hasList) {
      Content(`
  test "should direct list ${ename}" do
    canned = S.jt([S.jm(["id", "direct01"]), S.jm(["id", "direct02"])])
    sdk = mk(canned)
    res = ${Name}.direct(sdk, H.deep(%{"path" => "/${ename}", "method" => "GET", "params" => %{}}))
    assert S.getprop(res, "ok") == true
    assert H.to_int(S.getprop(res, "status")) == 200
    assert S.islist(S.getprop(res, "data"))
    assert S.size(S.getprop(res, "data")) == 2
    assert_received {:called, _url}
  end
`)
    }

    if (hasLoad) {
      Content(`
  test "should direct load ${ename}" do
    canned = S.jm(["id", "direct01"])
    sdk = mk(canned)
    res = ${Name}.direct(sdk, H.deep(%{"path" => "/${ename}/direct01", "method" => "GET", "params" => %{}}))
    assert S.getprop(res, "ok") == true
    assert H.to_int(S.getprop(res, "status")) == 200
    data = S.getprop(res, "data")
    assert S.ismap(data)
    assert S.getprop(data, "id") == "direct01"
    assert_received {:called, _url}
  end
`)
    }

    Content(`end
`)
  })
})


export {
  TestDirect
}
