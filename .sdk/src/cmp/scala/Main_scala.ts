
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


import { Package } from './Package_scala'
import { Config } from './Config_scala'
import { Gitignore } from './Gitignore_scala'
import { MainEntity } from './MainEntity_scala'
import { EntityBase } from './EntityBase_scala'
import { EntityTypes } from './EntityTypes_scala'
import { scalaPackage } from './utility_scala'


const Main = cmp(async function Main(props: any) {

  const { target } = props
  const { model } = props.ctx$

  const entity: ModelEntity = getModelPath(model, `main.${KIT}.entity`)
  const feature = getModelPath(model, `main.${KIT}.feature`)

  // The Scala package root for every runtime piece (like GOMODULE for go).
  const scalapackage = scalaPackage(model)

  Package({ target })

  Gitignore({})

  // Copy tm/scala files with replacements. SCALAPACKAGE is the package-root
  // token used throughout the templates (package/import statements);
  // ProjectName carries the SDK name into vendored template strings.
  Copy({
    from: 'tm/' + target.name,
    exclude: [/src\//],
    replace: {
      ...props.ctx$.stdrep,
      ProjectName: model.const.Name,
      SCALAPACKAGE: scalapackage,
    }
  })

  // Shared entity runtime (entity/EntityBase.scala).
  EntityBase({ target })

  // Generate the client class and config in core/.
  Folder({ name: 'core' }, () => {

    File({ name: model.const.Name + 'SDK.' + target.ext }, () => {

      Fragment(
        {
          from: Path.normalize(__dirname + '/../../../src/cmp/scala/fragment/Main.fragment.scala'),
          replace: {
            ...props.ctx$.stdrep,
            SCALAPACKAGE: scalapackage,
            ProjectName: model.const.Name,
          }
        },

        // Entities - injected at SLOT
        () => {
          each(entity, (entity: ModelEntity) => {
            const entitySDK = getModelPath(model, `main.${KIT}.entity.${entity.name}`)
            const entprops = { target, entity, entitySDK, scalapackage }
            MainEntity(entprops)
          })
        })
    })

    Config({ target })

    // Generate the typed reference-model file (<Name>Types.scala) beside the
    // other generated core files. Documentation/DX shapes only — not wired
    // into the loose-object-model op signatures.
    EntityTypes({ target, scalapackage })
  })

})


export {
  Main
}
