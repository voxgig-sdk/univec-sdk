
import type {
  ModelEntity
} from '@voxgig/apidef'

import { cmp, each, Folder, File, Content, entityCollection } from '@voxgig/sdkgen'


import { TestEntity } from './TestEntity_elixir'
import { TestDirect } from './TestDirect_elixir'
import { ReadmeExamplesTest } from './ReadmeExamplesTest_elixir'


const Test = cmp(function Test(props: any) {
  const { model } = props.ctx$
  const { target } = props

  const Name = model.const.Name

  Folder({ name: 'test' }, () => {

    File({ name: 'exists_test.exs' }, () => {
      Content(`defmodule ${Name}.ExistsTest do
  use ExUnit.Case

  test "should create test sdk" do
    testsdk = ${Name}.test()
    assert testsdk != nil
  end
end
`)
    })

    const entity = each(entityCollection(model))
      .filter((e: any) => false !== e.active)

    each(entity, (entity: ModelEntity) => {
      TestEntity({ target, entity })
      TestDirect({ target, entity })
    })

    // Validate the documented elixir examples in the README/REFERENCE docs.
    ReadmeExamplesTest({ target })
  })
})


export {
  Test
}
