
import * as Path from 'node:path'

import { swiftTargetDir, swiftTestDir } from './utility_swift'

import {
  cmp, camelify, names,
  Content, File, Folder, Fragment,
  entityClassName, entityCollection,
} from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath
} from '@voxgig/apidef'

import { EntityOperation } from './EntityOperation_swift'


const Entity = cmp(function Entity(props: any) {
  const { model, stdrep } = props.ctx$
  const { target, entity } = props

  // Collision-free entity CLASS name (see entityClassName).
  const entityColl = entityCollection(model)
  const cls = entityClassName(entity, entityColl)

  const entrep = {
    ...stdrep,
  }

  names(entrep, entity.Name, 'EntityName')

  const ff = Path.normalize(__dirname + '/../../../src/cmp/swift/fragment/')

  // Entity files join the copied runtime under Sources/ProjectNameSDK/entity.
  Folder({ name: 'Sources' }, () => {
    Folder({ name: swiftTargetDir(model) }, () => {
      Folder({ name: 'entity' }, () => {

        File({ name: cls + '.' + target.ext }, () => {

          const opnames = Object.keys(entity.op || {})

          // For each CRUD op: if the spec defines it, splice in the real
          // implementation (an override). Otherwise leave the base-class
          // method, which throws unsupportedOp at runtime.
          const opfrags =
            (['load', 'list', 'create', 'update', 'remove']
              .reduce((a: any, opname: string) =>
              (a['#' + camelify(opname) + 'Op'] =
                !opnames.includes(opname) ?
                  ({ indent }: any) => {
                    Content({ indent },
                      `// (${opname} not defined by this API - base class throws unsupportedOp)
`)
                  } :
                  ({ indent }: any) => {
                    EntityOperation({ ff, opname, indent, entity, entrep, cls })
                  }, a), {}))

          Fragment({
            from: ff + 'Entity.fragment.swift',
            replace: {
              ...entrep,
              ProjectName: model.const.Name,
              EntityName: entity.Name,
              entityname: entity.name,

              // Class/constructor tokens are decoupled from the EntityName
              // data-type token so the class can be renamed independently.
              EntyClass: cls,

              ...opfrags,
            }
          })

        })
      })
    })
  })
})



export {
  Entity
}
