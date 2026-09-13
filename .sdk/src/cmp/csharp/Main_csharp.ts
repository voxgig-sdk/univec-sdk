
import * as Path from 'node:path'

import {
  cmp, each,
  File, Content, Copy, Folder, Fragment,
  pluginExcludes,
  TEST_CONTROL_EXCLUDE
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
  //
  // pluginExcludes: the generate-time plugin trim (a DECLARED-but-INACTIVE
  // plugin group's files are never copied). Without it every group's files
  // ship regardless of the model, and an SDK whose chain is [dotenv, env]
  // carries AWS request signing and seven HTTP vault clients - the whole
  // point of the trim. Feature-level trimming happens at `target add`
  // time; this is the per-plugin cut inside a feature that IS selected.
  Copy({
    from: 'tm/' + target.name,
    exclude: [/src\//, TEST_CONTROL_EXCLUDE, ...pluginExcludes(model)],
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
