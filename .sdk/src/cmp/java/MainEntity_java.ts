

import { cmp, Content, entityClassName, entityCollection } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { javaPackage, javaVarName } from './utility_java'


// Emits the per-entity accessor on the generated client class (injected
// at the Main fragment SLOT). Java accessors are camelCase methods
// (client.planet(null).list(null, null)).
const MainEntity = cmp(async function MainEntity(props: any) {
  const { entity } = props
  const { model } = props.ctx$

  const javapackage = javaPackage(model)
  const entityColl = entityCollection(model)
  const cls = entityClassName(entity, entityColl)
  const accessor = javaVarName(entity.name)

  Content(`
  /**
   * Returns a ${entity.name} entity bound to this client.
   * Idiomatic usage: client.${accessor}(null).list(null, null) or
   * client.${accessor}(null).load(Map.of("id", ...), null).
   */
  public SdkEntity ${accessor}(Map<String, Object> entopts) {
    return new ${javapackage}.entity.${cls}(this, entopts);
  }
`)

})


export {
  MainEntity
}
