
import {
  Content,
  File,
  Folder,
  cmp,
  each,
} from '@voxgig/sdkgen'


import {
  KIT,
  getModelPath
} from '@voxgig/apidef'


import { cppVarName } from './utility_cpp'


// entity/entities.hpp — the entity umbrella header: includes every generated
// entity client header (the client accessors need them complete).
const EntityBase = cmp(async function EntityBase(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const entity = getModelPath(model, `main.${KIT}.entity`)

  Folder({ name: 'entity' }, () => {
    File({ name: 'entities.' + target.ext }, () => {
      Content(`// ${model.const.Name} SDK entities (generated).

#ifndef SDK_ENTITY_ENTITIES_HPP
#define SDK_ENTITY_ENTITIES_HPP

`)
      each(entity, (ent: any) => {
        Content(`#include "${cppVarName(ent.name)}.${target.ext}"
`)
      })

      Content(`
#endif // SDK_ENTITY_ENTITIES_HPP
`)
    })
  })
})


export {
  EntityBase
}
