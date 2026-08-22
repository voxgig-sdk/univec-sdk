

import { cmp, Content, entityClassName, entityCollection } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { scalaPackage, scalaVarName } from './utility_scala'


// Emits the per-entity accessor on the generated client class (injected at
// the Main fragment SLOT). Scala accessors are camelCase methods
// (client.planet(null).list(null, null)).
const MainEntity = cmp(async function MainEntity(props: any) {
  const { entity } = props
  const { model } = props.ctx$

  const scalapackage = scalaPackage(model)
  const entityColl = entityCollection(model)
  const cls = entityClassName(entity, entityColl)
  const accessor = scalaVarName(entity.name)

  Content(`
  /**
   * Returns a ${entity.name} entity bound to this client.
   * Idiomatic usage: client.${accessor}(null).list(null, null) or
   * client.${accessor}(null).load(java.util.Map.of("id", ...), null).
   */
  def ${accessor}(entopts: java.util.Map[String, Object]): SdkEntity =
    new ${scalapackage}.entity.${cls}(this, entopts)
`)

})


export {
  MainEntity
}
