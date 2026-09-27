
import * as Path from 'node:path'

import { swiftSecretsActive, swiftTargetDir, swiftTestDir } from './utility_swift'

import {
  cmp, each,
  File, Content, Copy, Folder, Fragment,
  pluginExcludes,
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
import { Schema } from './Schema_swift'
import { PrepareAuth } from './PrepareAuth_swift'
import { Gitignore } from './Gitignore_swift'
import { MainEntity } from './MainEntity_swift'
import { SdkError } from './SdkError_swift'
import { EntityBase } from './EntityBase_swift'
import { EntityTypes } from './EntityTypes_swift'


const Main = cmp(async function Main(props: any) {

  const { target } = props
  const { model } = props.ctx$

  const entity: ModelEntity = getModelPath(model, `main.${KIT}.entity`)

  const secrets = swiftSecretsActive(model, target)
  const secretsSourceExcludes: RegExp[] = secrets ? [] : [
    /(^|\/)feature\/SecretsFeature\.swift$/,
    /(^|\/)feature\/secrets\//,
  ]
  const secretsTestExcludes: RegExp[] = secrets ? [] : [
    /(^|\/)feature\/secrets\//,
  ]

  Package({ target })

  Gitignore({})

  Copy({
    from: 'tm/' + target.name,
    exclude: [/src\//, /Sources\//, /Tests\//],
    replace: {
      ...props.ctx$.stdrep,
      ProjectName: model.const.Name,
    }
  })

  Folder({ name: 'Sources' }, () => {
    Copy({
      from: 'tm/' + target.name + '/Sources/ProjectNameSDK',
      to: swiftTargetDir(model),
      exclude: [...secretsSourceExcludes, ...pluginExcludes(model)],
      replace: {
        ...props.ctx$.stdrep,
        ProjectName: model.const.Name,
      }
    })
  })

  Folder({ name: 'Tests' }, () => {
    Copy({
      from: 'tm/' + target.name + '/Tests/ProjectNameSDKTests',
      to: swiftTestDir(model),
      exclude: secretsTestExcludes,
      replace: {
        ...props.ctx$.stdrep,
        ProjectName: model.const.Name,
      }
    })

    // The vendored @voxgig/omni corpus engine. Its path is FIXED (Package
    // .swift declares an `Omni` target over Tests/vendor/omni, and the port
    // calls `Omni.errify` by module name), and its files are vendored
    // verbatim - no ProjectName substitution, which would rewrite an
    // upstream file.
    Copy({
      from: 'tm/' + target.name + '/Tests/vendor',
      to: 'vendor',
    })
  })

  // Generated sources join the copied runtime under Sources/ProjectNameSDK.
  Folder({ name: 'Sources' }, () => {
    Folder({ name: swiftTargetDir(model) }, () => {
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

        Schema({ target })

        SdkError({ target })

        EntityBase({ target })
      })
    })
  })

  PrepareAuth({ target })

  // entity/<Name>Types.swift — documentary typed models (one struct per entity
  // + per op). Compiles with the SwiftPM target; nothing consumes it yet.
  EntityTypes({ target })
})


export {
  Main
}
