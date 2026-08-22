
import type {
  ModelEntity
} from '@voxgig/apidef'

import { cmp, each, Folder, entityCollection } from '@voxgig/sdkgen'


import { TestDirect } from './TestDirect_js'
import { TestEntity } from './TestEntity_js'


const Test = cmp(function Test(props: any) {
  const { model, stdrep } = props.ctx$
  const { target } = props

  Folder({ name: 'test' }, () => {

    Folder({ name: 'entity' }, () => {
      const entity = each(entityCollection(model))
        .filter((e: any) => false !== e.active)
      each(entity, (entity: ModelEntity) => {
        TestEntity({ target, entity })
        TestDirect({ target, entity })
      })
    })
  })
})


export {
  Test
}
