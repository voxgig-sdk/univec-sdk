
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


import { Package } from './Package_kotlin'
import { Config } from './Config_kotlin'
import { Gitignore } from './Gitignore_kotlin'
import { MainEntity } from './MainEntity_kotlin'
import { EntityBase } from './EntityBase_kotlin'
import { EntityTypes } from './EntityTypes_kotlin'
import { SdkError } from './SdkError_kotlin'
import { kotlinPackage } from './utility_kotlin'


const Main = cmp(async function Main(props: any) {

  const { target } = props
  const { model } = props.ctx$

  const entity: ModelEntity = getModelPath(model, `main.${KIT}.entity`)

  // The Kotlin package root for every runtime piece (like GOMODULE for go):
  // e.g. voxgig-sdk + solardemo -> voxgig.solardemosdk -> .core etc.
  const kotlinpackage = kotlinPackage(model)

  Package({ target })

  Gitignore({})

  // Copy tm/kotlin files with replacements. KOTLINPACKAGE is the package root
  // token used throughout the templates (package/import statements).
  Copy({
    from: 'tm/' + target.name,
    exclude: [/src\//],
    replace: {
      ...props.ctx$.stdrep,
      KOTLINPACKAGE: kotlinpackage,
    }
  })

  // Shared entity runtime (entity/EntityBase.kt).
  EntityBase({ target })

  // Generate the client class and config in core/.
  Folder({ name: 'core' }, () => {

    SdkError({ target })

    File({ name: model.const.Name + 'SDK.' + target.ext }, () => {

      Fragment(
        {
          from: Path.normalize(__dirname + '/../../../src/cmp/kotlin/fragment/Main.fragment.kt'),
          replace: {
            ...props.ctx$.stdrep,
            KOTLINPACKAGE: kotlinpackage,
            ProjectName: model.const.Name,
          }
        },

        // Entities - injected at SLOT
        () => {
          each(entity, (entity: ModelEntity) => {
            const entitySDK = getModelPath(model, `main.${KIT}.entity.${entity.name}`)
            const entprops = { target, entity, entitySDK, kotlinpackage }
            MainEntity(entprops)
          })
        })
    })

    Config({ target })

    // Generate the typed reference-model file (<Name>Types.kt) beside the
    // other generated core files. Documentation/DX shapes only — not wired
    // into the loose-object-model op signatures.
    EntityTypes({ target, kotlinpackage })
  })

})


export {
  Main
}
