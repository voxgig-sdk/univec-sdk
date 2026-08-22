
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


import { Package } from './Package_swift'
import { Config } from './Config_swift'
import { Gitignore } from './Gitignore_swift'
import { MainEntity } from './MainEntity_swift'
import { SdkError } from './SdkError_swift'
import { EntityBase } from './EntityBase_swift'
import { EntityTypes } from './EntityTypes_swift'


const Main = cmp(async function Main(props: any) {

  const { target } = props
  const { model } = props.ctx$

  const entity: ModelEntity = getModelPath(model, `main.${KIT}.entity`)

  Package({ target })

  Gitignore({})

  // Copy tm/swift files with replacements. `src/` holds only the per-feature
  // extension folders (not shipped into the SDK output).
  Copy({
    from: 'tm/' + target.name,
    exclude: [/src\//],
    replace: {
      ...props.ctx$.stdrep,
      ProjectName: model.const.Name,
    }
  })

  // Generated sources join the copied runtime under Sources/ProjectNameSDK.
  Folder({ name: 'Sources' }, () => {
    Folder({ name: 'ProjectNameSDK' }, () => {
      Folder({ name: 'core' }, () => {

        // Main SDK client class, with entity accessors injected at the SLOT.
        File({ name: model.const.Name + 'SDK.' + target.ext }, () => {

          Fragment(
            {
              from: Path.normalize(
                __dirname + '/../../../src/cmp/swift/fragment/Main.fragment.swift'),
              replace: {
                ...props.ctx$.stdrep,
                ProjectName: model.const.Name,

                '#Feature-Hook': ({ name, indent }: any) => Content({ indent },
                  `utility.featureHook(rootctx, "${name}")
`),
              }
            },

            // Entities - injected at SLOT
            () => {
              each(entity, (entity: ModelEntity) => {
                MainEntity({ target, entity })
              })
            })
        })

        Config({ target })

        SdkError({ target })

        EntityBase({ target })
      })
    })
  })

  // entity/<Name>Types.swift — documentary typed models (one struct per entity
  // + per op). Compiles with the SwiftPM target; nothing consumes it yet.
  EntityTypes({ target })
})


export {
  Main
}
