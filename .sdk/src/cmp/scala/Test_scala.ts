
import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import type {
  ModelEntity
} from '@voxgig/apidef'

import { cmp, each, Folder, File, Content, entityCollection } from '@voxgig/sdkgen'


import { TestEntity } from './TestEntity_scala'
import { TestDirect } from './TestDirect_scala'
import { ReadmeExamplesTest } from './ReadmeExamplesTest_scala'
import { scalaPackage } from './utility_scala'


const Test = cmp(function Test(props: any) {
  const { model } = props.ctx$
  const { target } = props

  const scalapackage = scalaPackage(model)

  // The generated per-entity tests are scala-cli MAIN-scope objects (a
  // `test/` dir would be treated as test scope and excluded from
  // `scala-cli run`). They live in `sdktest/` alongside the runtime suite
  // (SdkTestMain), the struct corpus (Runner) and the shared SdkTestSupport
  // template, and are driven by the generated SdkEntityTestMain aggregator.
  Folder({ name: 'sdktest' }, () => {

    const entities: { Name: string; entity: boolean; direct: boolean }[] = []

    const entity = each(entityCollection(model))
      .filter((e: any) => false !== e.active)

    each(entity, (entity: ModelEntity) => {
      const EntityName = nom(entity, 'Name')

      const basicflow: any =
        getModelPath(model, `main.${KIT}.flow.Basic${EntityName}Flow`)
      const hasEntity = null != basicflow && true === basicflow.active

      const opnames = Object.keys(entity.op || {})
      const hasDirect = opnames.includes('load') || opnames.includes('list')

      if (hasEntity) {
        TestEntity({ target, entity, scalapackage })
      }
      if (hasDirect) {
        TestDirect({ target, entity, scalapackage })
      }

      if (hasEntity || hasDirect) {
        entities.push({ Name: EntityName, entity: hasEntity, direct: hasDirect })
      }
    })

    // Documentation scala-examples presence + structure gate over the root
    // README, scala/README.md and scala/REFERENCE.md. Driven through the same
    // shared report by the SdkEntityTestMain aggregator below.
    ReadmeExamplesTest({ target, scalapackage })

    // Aggregating main: run every generated per-entity test through one
    // shared report and exit non-zero on any failure.
    File({ name: 'SdkEntityTestMain.' + target.ext }, () => {
      Content(`// Aggregating entry point for the generated per-entity SDK tests. Drives
// every <Entity>EntityTest / <Entity>DirectTest object through one shared
// SdkTestReport and exits non-zero on any failure.
// Run: scala-cli run . --main-class SdkEntityTestMain

object SdkEntityTestMain {

  def main(args: Array[String]): Unit = {
    val rep = new SdkTestReport()

`)
      for (const e of entities) {
        if (e.entity) {
          Content(`    ${e.Name}EntityTest.run(rep)
`)
        }
        if (e.direct) {
          Content(`    ${e.Name}DirectTest.run(rep)
`)
        }
      }
      Content(`
    ReadmeExamplesTest.run(rep)

    rep.finish("ENTITY")
  }
}
`)
    })
  })
})


export {
  Test
}
