
import * as Path from 'node:path'

import {
  cmp, each,
  List, File, Content, Copy, Folder, Fragment, Line,
  entityClassName, entityCollection, pluginExcludes, targetFeatures,
  TEST_CONTROL_EXCLUDE
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

  // Gated by the applicability tags, so this target never emits a hook for
  // a feature it has no source for. One rule, one place:
  // helpers/applicability.
  const feature = targetFeatures(model, target)

  // Does the secrets feature apply here and is it switched on? Both, since
  // targetFeatures already dropped it for a target with no sekreto port.
  const secrets = null != feature.secrets

  Package({ target })

  Gitignore({})

  Copy({
    from: 'tm/' + target.name,
    exclude: [/^src\//, TEST_CONTROL_EXCLUDE, ...pluginExcludes(model)],
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

            '// #SecretsAccessor': () => secrets ?
              Content(`
  // The live sekreto chain this SDK resolves its credential through, for
  // callers who want arbitrary secrets or redaction:
  //
  //   await sdk.secrets().get('db.password')
  //   sdk.secrets().redact(logline)
  //
  // Null before the secrets feature has initialised, and in an SDK where
  // it is switched off.
  dynamic secrets() {
    for (final f in features) {
      if ('secrets' == f.name) {
        return f.sekreto();
      }
    }
    return null;
  }

`) : undefined,
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
