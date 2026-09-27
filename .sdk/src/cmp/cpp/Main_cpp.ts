
import * as Path from 'node:path'

import {
  cmp, each,
  File, Copy, Folder, Fragment,
  TEST_CONTROL_EXCLUDE,
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
  const esc = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const allfeature = getModelPath(model, `main.${KIT}.feature`,
    { required: false, only_active: false }) || {}
  const inactivePluginExcludes: RegExp[] = []
  for (const fname of Object.keys(allfeature)) {
    if (null != (feature as any)[fname]) continue
    const groups = getModelPath(model, `main.${KIT}.feature.${fname}.plugin`,
      { required: false, only_active: false }) || {}
    for (const gname of Object.keys(groups)) {
      for (const one of (groups[gname].path || [])) {
        const pat = esc(String(one))
        inactivePluginExcludes.push(new RegExp('(^|/)' +
          pat.replace(/\\\/$/, '') + (/\/$/.test(String(one)) ? '/' : '$')))
      }
    }
  }

  Package({ target })

  Gitignore({})

  Copy({
    from: 'tm/' + target.name,
    exclude: [/src\//, TEST_CONTROL_EXCLUDE,
      ...pluginExcludes(model), ...inactivePluginExcludes],
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
