
import {
  Content,
  File,
  Folder,
  cmp,
  each,
} from '@voxgig/sdkgen'


import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'


import { cIdent, cVarName } from './utility_c'


// core/api.h — the per-API public header: declares each entity's constructor
// and its SDK accessor (twin of the rust entity/mod.rs index). Every
// generated .c and every test includes this (it includes sdk.h in turn).
const EntityBase = cmp(async function EntityBase(props: any) {
  const { model } = props.ctx$

  const Name = model.const.Name
  const ident = cIdent(model)
  const guard = ident.toUpperCase().replace(/[^A-Z0-9_]/g, '_') + '_API_H'

  const entity = getModelPath(model, `main.${KIT}.entity`)

  Folder({ name: 'core' }, () => {
    File({ name: 'api.h' }, () => {
      Content(`// ${Name} SDK public API (generated).

#ifndef ${guard}
#define ${guard}

#include "sdk.h"

`)
      each(entity, (ent: any) => {
        const evar = cVarName(ent.name)
        Content(`// ${ent.Name} entity.
Entity* ${evar}_entity_new(${Name}SDK* client, voxgig_value* entopts);
Entity* ${ident}_${evar}(${Name}SDK* client, voxgig_value* entopts);
voxgig_value* ${evar}_stream(Entity* e, const char* action, voxgig_value* args, voxgig_value* callopts, PNError** err);
`)
      })

      Content(`
#endif // ${guard}
`)
    })
  })
})


export {
  EntityBase
}
