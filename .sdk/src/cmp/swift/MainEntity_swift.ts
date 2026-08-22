
import { cmp, Content, entityClassName, entityCollection } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath
} from '@voxgig/apidef'


const MainEntity = cmp(async function MainEntity(props: any) {
  const { entity } = props
  const { model } = props.ctx$

  // Collision-free entity CLASS name (see entityClassName).
  const entityColl = entityCollection(model)
  const cls = entityClassName(entity, entityColl)

  const Name = model.const.Name

  // Idiomatic usage: try client.${entity.Name}().list(nil) / .load(...).
  Content(`
  // ${entity.Name} returns a ${entity.Name} entity bound to this client.
  // Idiomatic usage: try client.${entity.Name}().list(nil) or
  // try client.${entity.Name}().load(vm(("id", .string("..."))), nil).
  public func ${entity.Name}(_ entopts: VMap? = nil) -> ${Name}EntityBase {
    return ${cls}(self, entopts)
  }
`)

})


export {
  MainEntity
}
