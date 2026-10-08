
import * as Path from 'node:path'

import {
  cmp, each,
  File, Copy, Folder, Fragment,
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


import { Package } from './Package_c'
import { Config, FeaturePlugins } from './Config_c'
import { Schema } from './Schema_c'
import { Gitignore } from './Gitignore_c'
import { MainEntity } from './MainEntity_c'
import { EntityBase } from './EntityBase_c'
import { EntityTypes } from './EntityTypes_c'
import { PrepareAuth } from './PrepareAuth_c'


const Main = cmp(async function Main(props: any) {

  const { target } = props
  const { model } = props.ctx$

  const entity: ModelEntity = getModelPath(model, `main.${KIT}.entity`)

  const feature = targetFeatures(model, target)

  Package({ target })

  Gitignore({})

  Copy({
    from: 'tm/' + target.name,
    exclude: [/src\//,
      ...inactiveFeatureExcludes(props.ctx$, target), ...pluginExcludes(model)],
    replace: {
      ...props.ctx$.stdrep,
    }
  })

  // Generated core files; the branded error type is a template (core/error.c).
  Folder({ name: 'core' }, () => {

    File({ name: 'client.c' }, () => {

      Fragment(
        {
          from: Path.normalize(__dirname + '/../../../src/cmp/c/fragment/Main.fragment.c'),
          replace: {
            ...props.ctx$.stdrep,
          }
        },

        () => {
          each(entity, (entity: ModelEntity) => {
            MainEntity({ target, entity })
          })
        })
    })

    Config({ target })

    Schema({ target })
  })

  PrepareAuth({ target })

  // feature/<name>/kinds.c — the plugin definitions an active plugin-bearing
  // feature selected, and the Makefile's wiring gate for that feature's
  // vendored payload (see Config_c). Nothing is emitted when no such
  // feature is active.
  FeaturePlugins({ target })

  // core/api.h — the per-API public header (entity constructors + accessors).
  EntityBase({ target })

  // entity/types.h — documentary typed models (one struct per entity + op).
  EntityTypes({ target })

})


export {
  Main
}
