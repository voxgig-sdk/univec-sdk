

import { cmp, Content } from '@voxgig/sdkgen'

import { entityModule, ocamlString, ocamlVarName } from './utility_ocaml'


// Entity accessor on the SDK client, injected into sdk_client.ml. Idiomatic
// usage:  Sdk_client.product client Noval  |> ... .e_list ...
const MainEntity = cmp(async function MainEntity(props: any) {
  const { entity } = props

  const fn = ocamlVarName(entity.name)
  const mod = entityModule(entity.name)
  const Mod = mod.charAt(0).toUpperCase() + mod.slice(1)

  Content(`
(* ${entity.Name} entity bound to a client:  ${fn} client entopts *)
let ${fn} (client : sdk_client) (entopts : value) : entity_obj =
  ${Mod}.make client entopts
`)

})


export {
  MainEntity
}
