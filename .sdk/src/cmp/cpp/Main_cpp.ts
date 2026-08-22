
import * as Path from 'node:path'

import {
  cmp, each,
  File, Content, Copy, Folder, Fragment,
} from '@voxgig/sdkgen'


import type {
  ModelEntity
} from '@voxgig/apidef'


import {
  KIT,
  getModelPath
} from '@voxgig/apidef'


import { Package } from './Package_cpp'
import { Config } from './Config_cpp'
import { Gitignore } from './Gitignore_cpp'
import { MainEntity } from './MainEntity_cpp'
import { EntityBase } from './EntityBase_cpp'
import { EntityTypes } from './EntityTypes_cpp'


const Main = cmp(async function Main(props: any) {

  const { target } = props
  const { model } = props.ctx$

  const entity: ModelEntity = getModelPath(model, `main.${KIT}.entity`)

  Package({ target })

  Gitignore({})

  // Copy tm/cpp verbatim (with placeholder substitution). The tm src/ subtree
  // only stages the per-feature custom-source dirs (target add), so exclude it.
  Copy({
    from: 'tm/' + target.name,
    exclude: [/src\//],
    replace: {
      ...props.ctx$.stdrep,
    }
  })

  // entity/entities.hpp — the entity umbrella (declares every entity header).
  EntityBase({ target })

  // <sdk>_types.hpp — documentation/reference structs (not used by the
  // Value-based runtime; safe convenience types for consumers).
  EntityTypes({ target })

  Folder({ name: 'core' }, () => {

    Config({ target })

    // core/client.hpp — the generated client class with entity accessors.
    File({ name: 'client.' + target.ext }, () => {

      Fragment(
        {
          from: Path.normalize(__dirname + '/../../../src/cmp/cpp/fragment/Main.fragment.cpp'),
          replace: {
            ...props.ctx$.stdrep,
            ProjectName: model.const.Name,
          }
        },

        // Entity accessors — injected at SLOT.
        () => {
          each(entity, (entity: ModelEntity) => {
            const entitySDK = getModelPath(model, `main.${KIT}.entity.${entity.name}`)
            const entprops = { target, entity, entitySDK }
            MainEntity(entprops)
          })
        })
    })
  })

})


export {
  Main
}
