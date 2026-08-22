
import { cmp, Content } from '@voxgig/sdkgen'

import { cIdent, cVarName } from './utility_c'


// Entity accessor free-function on the SDK client, injected at the Main
// fragment SLOT (file scope in client.c). Idiomatic usage:
//   Entity* e = solar_planet(sdk, NULL);
//   e->vt->list(e, match, ctrl, &err);
const MainEntity = cmp(async function MainEntity(props: any) {
  const { entity } = props
  const { model } = props.ctx$

  const Name = model.const.Name
  const ident = cIdent(model)
  const evar = cVarName(entity.name)

  Content(`
// ${entity.Name} entity bound to this client.
Entity* ${ident}_${evar}(${Name}SDK* client, voxgig_value* entopts) {
  return ${evar}_entity_new(client, entopts);
}
`)

})


export {
  MainEntity
}
