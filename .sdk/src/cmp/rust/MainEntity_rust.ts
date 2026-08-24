

import { cmp, Content, entityClassName, entityCollection } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath
} from '@voxgig/apidef'

import { rustVarName, rustMethodName } from './utility_rust'


// Entity accessor method on the SDK client, injected at the Main fragment
// SLOT (inside `impl ProjectNameSDK`). Idiomatic usage:
//   client.planet(Value::Noval).list(Value::Noval, Value::Noval)
const MainEntity = cmp(async function MainEntity(props: any) {
  const { entity } = props
  const { model } = props.ctx$

  const entityColl = entityCollection(model)
  const cls = entityClassName(entity, entityColl)
  const method = rustMethodName(entity.name)
  const mod = rustVarName(entity.name)

  Content(`
    /// ${entity.Name} entity bound to this client.
    pub fn ${method}(self: &Rc<Self>, entopts: Value) -> Rc<crate::entity::${mod}::${cls}> {
        crate::entity::${mod}::${cls}::new(self, entopts)
    }
`)

})


export {
  MainEntity
}
