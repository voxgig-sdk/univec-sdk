
import { cmp, Content, entityClassName, entityCollection } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { cppVarName } from './utility_cpp'


// Emits the per-entity accessor on the generated client class (injected at
// the Main fragment SLOT). Idiomatic usage:
//   client->planet()->list();  client->planet()->load(sdk::vmap({{"id", ...}}));
const MainEntity = cmp(async function MainEntity(props: any) {
  const { entity } = props
  const { model } = props.ctx$

  const entityColl = entityCollection(model)
  const cls = entityClassName(entity, entityColl)
  const accessor = cppVarName(entity.name)

  Content(`
  // ${entity.Name} entity bound to this client.
  std::shared_ptr<${cls}> ${accessor}(Value entopts = Value::undef()) {
    return std::make_shared<${cls}>(this, entopts);
  }
`)

})


export {
  MainEntity
}
