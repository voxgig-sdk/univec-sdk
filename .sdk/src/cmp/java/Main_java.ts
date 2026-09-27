
import * as Path from 'node:path'

import {
  cmp, each,
  File, Content, Copy, Folder, Fragment,
  pluginExcludes,
  targetFeatures,
  TEST_CONTROL_EXCLUDE
} from '@voxgig/sdkgen'


import type {
  ModelEntity
} from '@voxgig/apidef'


import {
  KIT,
  getModelPath
} from '@voxgig/apidef'


import { Package } from './Package_java'
import { Config } from './Config_java'
import { Schema } from './Schema_java'
import { Gitignore } from './Gitignore_java'
import { MainEntity } from './MainEntity_java'
import { EntityBase } from './EntityBase_java'
import { EntityTypes } from './EntityTypes_java'
import { SdkError } from './SdkError_java'
import { PrepareAuth } from './PrepareAuth_java'
import { javaPackage } from './utility_java'


const Main = cmp(async function Main(props: any) {

  const { target } = props
  const { model } = props.ctx$

  const entity: ModelEntity = getModelPath(model, `main.${KIT}.entity`)
  // Gated by the applicability tags, so this target never imports or
  // registers a feature it has no source for. One rule, one place:
  // helpers/applicability.
  const feature = targetFeatures(model, target)

  const javapackage = javaPackage(model)

  Package({ target })

  Gitignore({})

  // Copy tm/java files with replacements. JAVAPACKAGE is the package root
  // token used throughout the templates (package/import statements).
  Copy({
    from: 'tm/' + target.name,
    exclude: [/src\//, TEST_CONTROL_EXCLUDE, ...pluginExcludes(model)],
    replace: {
      ...props.ctx$.stdrep,
      JAVAPACKAGE: javapackage,
    }
  })

  EntityBase({ target })

  PrepareAuth({ target })

  Folder({ name: 'core' }, () => {

    SdkError({ target })

    File({ name: model.const.Name + 'SDK.' + target.ext }, () => {

      Fragment(
        {
          from: Path.normalize(__dirname + '/../../../src/cmp/java/fragment/Main.fragment.java'),
          replace: {
            ...props.ctx$.stdrep,
            JAVAPACKAGE: javapackage,
            ProjectName: model.const.Name,

            '#Feature-Hook': ({ name, indent }: any) => Content({ indent }, `
this.utility.featureHook.apply(this.rootctx, "${name}");
`),

          }
        },

        () => {
          each(entity, (entity: ModelEntity) => {
            const entitySDK = getModelPath(model, `main.${KIT}.entity.${entity.name}`)
            const entprops = { target, entity, entitySDK, javapackage }
            MainEntity(entprops)
          })
        })
    })

    Config({ target })
    Schema({ target })

    // Generate the typed reference-model file (<Name>Types.java) beside the
    // other generated core files. Documentation/DX shapes only — not wired
    // into the loose-object-model op signatures.
    EntityTypes({ target, javapackage })
  })

})


export {
  Main
}
