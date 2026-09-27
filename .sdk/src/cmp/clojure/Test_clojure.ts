
import type {
  ModelEntity
} from '@voxgig/apidef'

import { cmp, each, File, Content, Folder, entityCollection } from '@voxgig/sdkgen'

import { TestEntity } from './TestEntity_clojure'
import { TestDirect } from './TestDirect_clojure'
import { ReadmeExamplesTest } from './ReadmeExamplesTest_clojure'


const Test = cmp(function Test(props: any) {
  const { model } = props.ctx$
  const { target } = props

  const entity: ModelEntity[] = each(entityCollection(model))
    .filter((e: any) => false !== e.active)

  Folder({ name: 'test' }, () => {
    Folder({ name: 'sdk' }, () => {
      File({ name: 'gentest.' + target.ext }, () => {

        let requires = ''
        each(entity, (e: any) => {
          requires += `\n            [sdk.entity.${e.name} :as e-${e.name}]`
        })

        Content(`;; ${model.const.Name} SDK generated API tests.
(ns sdk.gentest
  (:require [sdk.api :as api]
            [sdk.config :as config]
            [sdk.testutil :as t]
            [clojure.string]
            [voxgig.struct :as vs]${requires}))

(defn run [rec]
`)

        // Per-entity accessor / create+list smoke / stream checks
        // (sorted-key order via each() keeps output byte-stable).
        each(entity, (e: any) => {
          TestEntity({ target, entity: e })
        })

        // Per-entity direct()/prepare() escape-hatch checks.
        each(entity, (e: any) => {
          TestDirect({ target, entity: e })
        })

        // Documentation clojure-examples syntax gate.
        ReadmeExamplesTest({ target })

        Content(`  nil)
`)
      })
    })
  })
})


export {
  Test
}
