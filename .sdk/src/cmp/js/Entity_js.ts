
import * as Path from 'node:path'

import {
  cmp, each, camelify, names,
  File, Content, Folder, Fragment, Line, FeatureHook, Slot,
  entityClassName, entityCollection,
} from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath
} from '@voxgig/apidef'

import { EntityOperation } from './EntityOperation_js'


const Entity = cmp(function Entity(props: any) {
  const { model, stdrep } = props.ctx$
  const { target, entity } = props

  // Collision-free entity CLASS name (see entityClassName): normally
  // `<Name>Entity`, disambiguated when it would clash with another entity's
  // data-type name. The class file name and the Main require path both use this.
  const entityColl = entityCollection(model)
  const cls = entityClassName(entity, entityColl)

  const entrep = {
    ...stdrep,
  }

  names(entrep, entity.Name, 'EntityName')

  const ff = Path.normalize(__dirname + '/../../../src/cmp/js/fragment/')

  Folder({ name: 'src/entity' }, () => {

    File({ name: cls + '.' + target.name }, () => {

      const opnames = Object.keys(entity.op || {})

      const opfrags =
        (['load', 'list', 'create', 'update', 'remove']
          .reduce((a: any, opname: string) =>
          (a['#' + camelify(opname) + 'Op'] =
            !opnames.includes(opname) ? '' : ({ indent }: any) => {
              EntityOperation({ ff, opname, indent, entity, entrep })
            }, a), {}))

      Fragment({
        from: ff + 'Entity.fragment.js',
        replace: {
          ...entrep,
          entityname: entity.name,
          SdkName: model.const.Name,
          EntityName: entity.Name,

          // Class token decoupled from the EntityName data-type token in
          // Entity.fragment.js so the class can be renamed independently.
          EntyClass: cls,

          '#Feature-Hook': ({ name, indent }: any) =>
            Content({ indent }, `
fres = featureHook(ctx, '${name}')
if (fres instanceof Promise) { await fres }
`.trim()),

          ...opfrags,
        }
      })

    })
  })
})



export {
  Entity
}
