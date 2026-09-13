
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
import { Gitignore } from './Gitignore_swift'
import { MainEntity } from './MainEntity_swift'
import { SdkError } from './SdkError_swift'
import { EntityBase } from './EntityBase_swift'
import { EntityTypes } from './EntityTypes_swift'


const Main = cmp(async function Main(props: any) {

  const { target } = props
  const { model } = props.ctx$

  const entity: ModelEntity = getModelPath(model, `main.${KIT}.entity`)

  // THE SECRETS TRIM, at generate time, and swift NEEDS it where go, py and
  // dart leave the feature-level trim to `target add` (vendor-tag rollout,
  // Decision 5). DELIBERATE DIVERGENCE, and the reason is the build: the
  // feature's three vendored trees are separate SwiftPM MODULES that
  // Package_swift declares only when the feature is active (see the note
  // there). With the feature off, a tree still in Sources/<Name>Sdk/ would
  // be folded into the SDK target and fail it on five redeclarations, and
  // feature/SecretsFeature.swift would fail on `import Sekreto` naming a
  // module the manifest never declared. Every other swift feature is a
  // single file the SDK module compiles regardless, so it needs no such
  // exclude. Keyed on the SAME predicate the manifest uses, so the two
  // cannot disagree. The gated suite under Tests/.../feature/secrets/ goes
  // with it: it imports Sekreto too.
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

  // Copy tm/swift files with replacements. `src/` holds only the per-feature
  // extension folders (not shipped into the SDK output).
  // THE COPIED TREE HAS TO CARRY THE API NAME TOO.
  //
  // Copy substitutes file CONTENTS, never path components, so a blanket copy
  // of tm/swift landed the runtime in a directory literally called
  // ProjectNameSDK. Package.swift papered over it with an explicit `path:`,
  // so it compiled and every swift suite passed — while every published SDK
  // shipped `Sources/ProjectNameSDK/`, and SwiftPM's own convention
  // (Sources/<target>) was broken in all of them.
  //
  // Copy's `to` prop names the destination, so the two placeholder subtrees
  // are copied explicitly and the rest of tm/swift blanket-copied as before.
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
      // pluginExcludes: the generate-time plugin trim (an ACTIVE feature's
      // INACTIVE plugin group's declared files stay out of the tree). The
      // model's swift `path` entries are relative to THIS Copy's root
      // (`feature/secrets/plugins/Aws.swift`, not `Sources/ProjectNameSDK/
      // ...`), as py's are to its pkg copy - helpers/featureSource documents
      // that getting the root wrong makes the trim a silent no-op. No
      // verbatim carve-out is needed for the vendored trees: none of the
      // upstream swift files carries a ProjectName/PROJECTENV token, so the
      // blanket replace is inert over them.
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
