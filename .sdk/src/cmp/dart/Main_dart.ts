
import * as Path from 'node:path'

import {
  cmp, each,
  List, File, Copy, Folder, Fragment, Line,
  entityClassName, entityCollection,
} from '@voxgig/sdkgen'


import type {
  ModelEntity
} from '@voxgig/apidef'


import {
  KIT,
  getModelPath
} from '@voxgig/apidef'


import { Package } from './Package_dart'
import { Config } from './Config_dart'
import { Gitignore } from './Gitignore_dart'
import { MainEntity } from './MainEntity_dart'
import { EntityBase } from './EntityBase_dart'
import { EntityTypes } from './EntityTypes_dart'
import { SdkError } from './SdkError_dart'


const Main = cmp(async function Main(props: any) {

  // Needs type: target object
  const { target } = props
  const { model } = props.ctx$

  const entity: ModelEntity = getModelPath(model, `main.${KIT}.entity`)

  Package({ target })

  Gitignore({})

  // Copy tm/dart files with replacements. The src/feature/* dirs exist only
  // for the feature-add copy mechanism (real feature sources live under
  // lib/feature/), so they are excluded from the generated package.
  Copy({
    from: 'tm/' + target.name,
    exclude: [/src\//],
    replace: {
      ...props.ctx$.stdrep,
    }
  })

  Folder({ name: 'lib' }, () => {

    SdkError({ target })

    File({ name: model.const.Name + 'SDK.' + target.ext }, () => {

      Line(`// ${model.const.Name} ${target.Name} SDK`)
      Line(``)

      List({ item: entity }, ({ item }: any) => {
        const cls = entityClassName(item, entityCollection(model))
        return Line(`import 'entity/${cls}.dart';`)
      })

      // Re-export the generated typed models and entity classes so
      // consumers can import everything from '<Sdk>SDK.dart'.
      Line(``)
      Line(`export '${model.const.Name}Types.dart';`)
      List({ item: entity }, ({ item }: any) => {
        const cls = entityClassName(item, entityCollection(model))
        return Line(`export 'entity/${cls}.dart';`)
      })

      Fragment(
        {
          from: Path.normalize(__dirname + '/../../../src/cmp/dart/fragment/Main.fragment.dart'),
          replace: {
            ...props.ctx$.stdrep,
          }
        },

        // Entities
        () => {
          each(entity, (entity: ModelEntity) => {
            const entitySDK = getModelPath(model, `main.${KIT}.entity.${entity.name}`)
            const entprops = { target, entity, entitySDK }
            MainEntity(entprops)
          })
        })
    })

    Config({ target })
    EntityBase({ target })
    EntityTypes({ target })

  })
})


export {
  Main
}
