
import type {
  ModelEntity
} from '@voxgig/apidef'

import { cmp, each, Folder, entityCollection } from '@voxgig/sdkgen'


import { TestEntity } from './TestEntity_java'
import { TestDirect } from './TestDirect_java'
import { ReadmeExamplesTest } from './ReadmeExamplesTest_java'
import { javaPackage } from './utility_java'


const Test = cmp(function Test(props: any) {
  const { model } = props.ctx$
  const { target } = props

  const javapackage = javaPackage(model)

  Folder({ name: 'test' }, () => {

    // The shared test infrastructure (RunnerSupport, FeatureHarness,
    // PipelineTest, FeatureTest, NetsimTest, PrimaryUtilityTest,
    // CustomUtilityTest, StructRunner/StructCorpusTest, ExistsTest and
    // sdk-test-control.json) ships as templates in tm/java/test/ and is
    // copied by Main_java. Here we generate only the API-specific tests.
    const entity = each(entityCollection(model))
      .filter((e: any) => false !== e.active)
    each(entity, (entity: ModelEntity) => {
      TestEntity({ target, entity, javapackage })
      TestDirect({ target, entity, javapackage })
    })

    // Validate the documented java examples in the root + per-language docs.
    ReadmeExamplesTest({ target, javapackage })
  })
})


export {
  Test
}
