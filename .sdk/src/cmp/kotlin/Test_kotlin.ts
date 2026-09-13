
import type {
  ModelEntity
} from '@voxgig/apidef'

import { cmp, each, Folder, entityCollection,
  TestControl } from '@voxgig/sdkgen'


import { TestEntity } from './TestEntity_kotlin'
import { TestDirect } from './TestDirect_kotlin'
import { ReadmeExamplesTest } from './ReadmeExamplesTest_kotlin'
import { kotlinPackage } from './utility_kotlin'


const Test = cmp(function Test(props: any) {
  const { model } = props.ctx$
  const { target } = props

  const kotlinpackage = kotlinPackage(model)

  Folder({ name: 'test' }, () => {

    // Write-once: a project's edited control file survives regeneration.
    TestControl({ target, dir: 'test' })

    // The shared test infrastructure (RunnerSupport, the vendored omni
    // runner under test/vendor/omni with its OmniResolver/OmniSmokeTest,
    // FeatureHarness, PipelineTest, FeatureTest, NetsimTest,
    // PrimaryUtilityTest, CustomUtilityTest, StructCorpusTest, ExistsTest
    // and sdk-test-control.json) ships as templates in tm/kotlin/test/ and
    // is copied by Main_kotlin. Here we generate only the API-specific tests.
    const entity = each(entityCollection(model))
      .filter((e: any) => false !== e.active)
    each(entity, (entity: ModelEntity) => {
      TestEntity({ target, entity, kotlinpackage })
      TestDirect({ target, entity, kotlinpackage })
    })

    // Validate the documented kotlin examples in the root + per-language docs.
    ReadmeExamplesTest({ target, kotlinpackage })
  })
})


export {
  Test
}
