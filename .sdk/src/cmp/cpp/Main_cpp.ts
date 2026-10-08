
import * as Path from 'node:path'

import {
  cmp, each,
  File, Copy, Folder, Fragment,
  TEST_CONTROL_EXCLUDE,
  inactiveFeatureExcludes,
  pluginExcludes,
  targetFeatures,
} from '@voxgig/sdkgen'


import type {
  ModelEntity
} from '@voxgig/apidef'


import {
  KIT,
  getModelPath
} from '@voxgig/apidef'


import { Package } from './Package_cpp'
import { Config, FeaturePlugins } from './Config_cpp'
import { Schema } from './Schema_cpp'
import { Gitignore } from './Gitignore_cpp'
import { MainEntity } from './MainEntity_cpp'
import { EntityBase } from './EntityBase_cpp'
import { EntityTypes } from './EntityTypes_cpp'
import { PrepareAuth } from './PrepareAuth_cpp'


const Main = cmp(async function Main(props: any) {

  const { target } = props
  const { model } = props.ctx$

  const entity: ModelEntity = getModelPath(model, `main.${KIT}.entity`)

  const feature = targetFeatures(model, target)

  Package({ target })

  Gitignore({})

  Copy({
    from: 'tm/' + target.name,
    exclude: [/src\//, TEST_CONTROL_EXCLUDE,
      ...inactiveFeatureExcludes(props.ctx$, target), ...pluginExcludes(model)],
    replace: {
      ...props.ctx$.stdrep,
    }
  })

  // entity/entities.hpp — the entity umbrella (declares every entity header).
  EntityBase({ target })

  // <sdk>_types.hpp — reference structs for consumers; the runtime ignores them.
  EntityTypes({ target })

  Folder({ name: 'core' }, () => {

    Config({ target })

    Schema({ target })

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

  PrepareAuth({ target })

  // feature/<name>/kinds.cpp — the plugin definitions an active
  // plugin-bearing feature selected, and the Makefile's wiring gate for that
  // feature's vendored payload (see Config_cpp). Nothing is emitted when no
  // such feature is active.
  FeaturePlugins({ target })

})


export {
  Main
}
