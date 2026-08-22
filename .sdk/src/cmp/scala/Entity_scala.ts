
import * as Path from 'node:path'

import {
  cmp, camelify, names,
  File, Content, Folder, Fragment,
  entityClassName, entityCollection,
} from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath
} from '@voxgig/apidef'

import { scalaPackage } from './utility_scala'
import { EntityOperation } from './EntityOperation_scala'


const Entity = cmp(function Entity(props: any) {
  const { model, stdrep } = props.ctx$
  const { target, entity } = props

  const scalapackage = scalaPackage(model)

  // Collision-free entity CLASS name.
  const entityColl = entityCollection(model)
  const cls = entityClassName(entity, entityColl)

  const entrep = {
    ...stdrep,
  }

  names(entrep, entity.Name, 'EntityName')

  const ff = Path.normalize(__dirname + '/../../../src/cmp/scala/fragment/')

  // Entity classes go to the entity/ folder.
  Folder({ name: 'entity' }, () => {

    File({ name: cls + '.' + target.ext }, () => {

      const opnames = Object.keys(entity.op || {})

      // For each CRUD op: if the spec defines it, splice in the real
      // implementation. Otherwise emit a stub that satisfies the SdkEntity
      // contract (so the package compiles) but errors at runtime.
      const opfrags =
        (['load', 'list', 'create', 'update', 'remove']
          .reduce((a: any, opname: string) =>
          (a['// #' + camelify(opname) + 'Op'] =
            !opnames.includes(opname) ?
              ({ indent }: any) => {
                Content({ indent }, `  override def ${opname}(req: java.util.Map[String, Object], ctrl: java.util.Map[String, Object]): Object =
    throw Helpers.unsupportedOp("${opname}", this.name)
`)
              } :
              ({ indent }: any) => {
                EntityOperation({ ff, opname, indent, entity, entrep, scalapackage, cls })
              }, a), {}))

      Fragment({
        from: ff + 'Entity.fragment.scala',
        replace: {
          ...entrep,
          SCALAPACKAGE: scalapackage,
          ProjectName: model.const.Name,
          EntityName: entity.Name,
          entityname: entity.name,

          // Class tokens are decoupled from the EntityName data-type token.
          EntyClass: cls,

          '#Entity-Hook': ({ name, indent }: any) =>
            Content({ indent }, `utility.featureHook(ctx, "${name}")`),

          ...opfrags,
        }
      })

    })
  })
})


export {
  Entity
}
