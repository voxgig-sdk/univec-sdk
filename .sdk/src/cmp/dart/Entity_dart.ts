
import * as Path from 'node:path'

import {
  cmp, camelify, names,
  Content, File, Folder, Fragment,
  entityClassName, entityCollection,
} from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath
} from '@voxgig/apidef'

import { EntityOperation } from './EntityOperation_dart'


const Entity = cmp(function Entity(props: any) {
  const { model, stdrep } = props.ctx$
  const { target, entity } = props

  // Collision-free entity CLASS name (see entityClassName): normally
  // `<Name>Entity`, disambiguated when it would clash with another entity's
  // data-type name. The class file name and the Main accessor both use
  // this, so they always agree.
  const entityColl = entityCollection(model)
  const cls = entityClassName(entity, entityColl)

  const entrep = {
    ...stdrep,
  }

  names(entrep, entity.Name, 'EntityName')

  const ff = Path.normalize(__dirname + '/../../../src/cmp/dart/fragment/')

  Folder({ name: 'lib/entity' }, () => {

    File({ name: cls + '.' + target.ext }, () => {

      const opnames = Object.keys(entity.op || {})

      const opfrags =
        (['load', 'list', 'create', 'update', 'remove']
          .reduce((a: any, opname: string) =>
          (a['#' + camelify(opname) + 'Op'] =
            !opnames.includes(opname) ? '' : ({ indent }: any) => {
              EntityOperation({ ff, opname, indent, entity, entrep })
            }, a), {}))

      Fragment({
        from: ff + 'Entity.fragment.dart',
        replace: {
          ...entrep,
          entityname: entity.name,
          SdkName: model.const.Name,
          EntityName: entity.Name,

          // Class token decoupled from the EntityName data-type token in
          // Entity.fragment.dart so the class can be renamed independently.
          EntyClass: cls,

          '#TypeImports': ({ indent }: any) => Content({ indent },
            `// Typed models: see ../${model.const.Name}Types.dart ` +
            `(${entity.Name} and the per-op request/match types).`),

          // dart:async (Future/Stream) and ErrUtility are only referenced by
          // op method bodies, so an op-less entity would import them unused.
          // Emit them only when the entity actually has operations.
          '#OpImports': opnames.length > 0
            ? ({ indent }: any) => Content({ indent },
              `import 'dart:async';\nimport '../utility/ErrUtility.dart';`)
            : '',

          ...opfrags,
        }
      })

    })
  })
})



export {
  Entity
}
