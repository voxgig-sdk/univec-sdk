
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


import { Package } from './Package_csharp'
import { Config } from './Config_csharp'
import { Gitignore } from './Gitignore_csharp'
import { MainEntity } from './MainEntity_csharp'
import { SdkError } from './SdkError_csharp'
import { EntityBase } from './EntityBase_csharp'
import { EntityTypes } from './EntityTypes_csharp'


const Main = cmp(async function Main(props: any) {

  const { target } = props
  const { model } = props.ctx$

  const entity: ModelEntity = getModelPath(model, `main.${KIT}.entity`)

  Package({ target })

  Gitignore({})

  // Copy tm/csharp files with replacements. `src/` holds only the
  // per-feature extension folders (not shipped into the SDK output).
  Copy({
    from: 'tm/' + target.name,
    exclude: [/src\//],
    replace: {
      ...props.ctx$.stdrep,
    }
  })

  // Generated files live in core/ beside the copied runtime.
  Folder({ name: 'core' }, () => {

    // Main SDK client class, with entity accessors injected at the SLOT.
    File({ name: model.const.Name + 'SDK.' + target.ext }, () => {

      Fragment(
        {
          from: Path.normalize(
            __dirname + '/../../../src/cmp/csharp/fragment/Main.fragment.cs'),
          replace: {
            ...props.ctx$.stdrep,
            ProjectNameSdk: model.const.Name + 'Sdk',
            ProjectName: model.const.Name,

            '#Feature-Hook': ({ name, indent }: any) => Content({ indent },
              `_utility.FeatureHook(_rootctx, "${name}");
`),
          }
        },

        // Entities - injected at SLOT
        () => {
          each(entity, (entity: ModelEntity) => {
            const entitySDK = getModelPath(model, `main.${KIT}.entity.${entity.name}`)
            MainEntity({ target, entity, entitySDK })
          })
        })
    })

    Config({ target })

    SdkError({ target })

    EntityBase({ target })

    // Generate the typed reference-model file (<Name>Types.cs) beside the
    // other generated core files. Documentation/DX shapes only — not wired
    // into the loose-object-model op signatures.
    EntityTypes({ target })
  })
})


export {
  Main
}
