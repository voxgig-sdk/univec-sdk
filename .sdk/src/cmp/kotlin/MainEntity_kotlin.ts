
import { cmp, Content, entityClassName, entityCollection } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { kotlinPackage, kotlinVarName } from './utility_kotlin'


// Emits the per-entity accessor on the generated client class (injected at
// the Main fragment SLOT). Kotlin accessors are camelCase methods
// (client.planet(null).list(null, null)).
const MainEntity = cmp(async function MainEntity(props: any) {
  const { entity } = props
  const { model } = props.ctx$

  const kotlinpackage = kotlinPackage(model)
  const entityColl = entityCollection(model)
  const cls = entityClassName(entity, entityColl)
  const accessor = kotlinVarName(entity.name)

  Content(`
  /**
   * Returns a ${entity.name} entity bound to this client.
   * Idiomatic usage: client.${accessor}(null).list(null, null) or
   * client.${accessor}(null).load(mutableMapOf("id" to ...), null).
   */
  fun ${accessor}(entopts: MutableMap<String, Any?>?): SdkEntity {
    return ${kotlinpackage}.entity.${cls}(this, entopts)
  }
`)

})


export {
  MainEntity
}
