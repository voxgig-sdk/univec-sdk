
import * as Path from 'node:path'

import {
  cmp, each,
  File, Content, Copy, Folder, Fragment,
  targetFeatures,
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


import { Package } from './Package_scala'
import { Config } from './Config_scala'
import { Schema } from './Schema_scala'
import { Gitignore } from './Gitignore_scala'
import { MainEntity } from './MainEntity_scala'
import { EntityBase } from './EntityBase_scala'
import { EntityTypes } from './EntityTypes_scala'
import { PrepareAuth } from './PrepareAuth_scala'
import { scalaPackage } from './utility_scala'


const Main = cmp(async function Main(props: any) {

  const { target } = props
  const { model } = props.ctx$

  const entity: ModelEntity = getModelPath(model, `main.${KIT}.entity`)
  // Gated by the applicability tags, so this target never imports or
  // registers a feature it has no source for. One rule, one place:
  // helpers/applicability.
  const feature = targetFeatures(model, target)

  // The Scala package root for every runtime piece (like GOMODULE for go).
  const scalapackage = scalaPackage(model)

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

  const SHARED_SEKRETO_PLUGINS = ['Httpjson.scala', 'Sigv4.scala']
  const pluginDirExcludes: RegExp[] = []
  if (null == (feature as any).secrets) {
    pluginDirExcludes.push(new RegExp(
      '(^|/)feature/secrets/sekreto/plugins/(?!' +
      SHARED_SEKRETO_PLUGINS.map((f) => esc(f)).join('|') + ')[^/]+$'))
  }

  Package({ target })

  Gitignore({})

  // Copy tm/scala files with replacements. SCALAPACKAGE is the package-root
  // token used throughout the templates (package/import statements);
  // ProjectName carries the SDK name into vendored template strings.
  Copy({
    from: 'tm/' + target.name,
    exclude: [
      /src\//,
      TEST_CONTROL_EXCLUDE,
      ...pluginExcludes(model),
      ...inactivePluginExcludes,
      ...pluginDirExcludes,
    ],
    replace: {
      ...props.ctx$.stdrep,
      ProjectName: model.const.Name,
      SCALAPACKAGE: scalapackage,
    }
  })

  // Shared entity runtime (entity/EntityBase.scala).
  EntityBase({ target })

  PrepareAuth({ target })

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

        () => {
          each(entity, (entity: ModelEntity) => {
            const entitySDK = getModelPath(model, `main.${KIT}.entity.${entity.name}`)
            const entprops = { target, entity, entitySDK, scalapackage }
            MainEntity(entprops)
          })
        })
    })

    Config({ target })

    Schema({ target })

    // Generate the typed reference-model file (<Name>Types.scala) beside the
    // other generated core files. Documentation/DX shapes only — not wired
    // into the loose-object-model op signatures.
    EntityTypes({ target, scalapackage })
  })

})


export {
  Main
}
