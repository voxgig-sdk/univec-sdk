
import type {
  ModelEntity
} from '@voxgig/apidef'

import { cmp, each, Folder, entityCollection } from '@voxgig/sdkgen'


import { TestEntity } from './TestEntity_cpp'
import { TestDirect } from './TestDirect_cpp'
import { ReadmeExamplesTest } from './ReadmeExamplesTest_cpp'


const Test = cmp(function Test(props: any) {
  const { model } = props.ctx$
  const { target } = props

  // The static test suite (exists / pipeline / primary / feature / custom /
  // netsim / struct corpus) ships as tm/cpp/test templates (copied verbatim).
  // Here we generate the per-entity model-driven tests into test/.
  Folder({ name: 'test' }, () => {
    const entity = each(entityCollection(model))
      .filter((e: any) => false !== e.active)
    each(entity, (entity: ModelEntity) => {
      TestEntity({ target, entity })
      TestDirect({ target, entity })
    })

    // Validate the documented C++ examples in the READMEs are well-formed.
    ReadmeExamplesTest({ target })
  })
})


export {
  Test
}
