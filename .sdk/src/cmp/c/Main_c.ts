
import * as Path from 'node:path'

import {
  cmp, each,
  File, Copy, Folder, Fragment,
} from '@voxgig/sdkgen'


import type {
  ModelEntity
} from '@voxgig/apidef'


import {
  KIT,
  getModelPath
} from '@voxgig/apidef'


import { Package } from './Package_c'
import { Config } from './Config_c'
import { Gitignore } from './Gitignore_c'
import { MainEntity } from './MainEntity_c'
import { EntityBase } from './EntityBase_c'
import { EntityTypes } from './EntityTypes_c'


const Main = cmp(async function Main(props: any) {

  const { target } = props
  const { model } = props.ctx$

  const entity: ModelEntity = getModelPath(model, `main.${KIT}.entity`)

  Package({ target })

  Gitignore({})

  // Copy tm/c files with replacements. The tm src/ subtree only stages the
  // per-feature custom-source dirs (target add), so it is excluded here.
  Copy({
    from: 'tm/' + target.name,
    exclude: [/src\//],
    replace: {
      ...props.ctx$.stdrep,
    }
  })

  // Generated core files: the client (client.c), the API config (config.c),
  // and the per-API header (api.h, via EntityBase). The branded error type
  // is a template (core/error.c).
  Folder({ name: 'core' }, () => {

    File({ name: 'client.c' }, () => {

      Fragment(
        {
          from: Path.normalize(__dirname + '/../../../src/cmp/c/fragment/Main.fragment.c'),
          replace: {
            ...props.ctx$.stdrep,
          }
        },

        // Entity accessors — injected at SLOT.
        () => {
          each(entity, (entity: ModelEntity) => {
            MainEntity({ target, entity })
          })
        })
    })

    Config({ target })
  })

  // core/api.h — the per-API public header (entity constructors + accessors).
  EntityBase({ target })

  // entity/types.h — documentary typed models (one struct per entity + op).
  EntityTypes({ target })

})


export {
  Main
}
