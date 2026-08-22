
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

import { javaPackage } from './utility_java'
import { EntityOperation } from './EntityOperation_java'


const Entity = cmp(function Entity(props: any) {
  const { model, stdrep } = props.ctx$
  const { target, entity } = props

  const javapackage = javaPackage(model)

  // Collision-free entity CLASS name (see entityClassName): normally
  // `<Name>Entity`, but disambiguated (e.g. `<Name>EntityClient`) when it
  // would clash with another entity's data-type name.
  const entityColl = entityCollection(model)
  const cls = entityClassName(entity, entityColl)

  const entrep = {
    ...stdrep,
  }

  names(entrep, entity.Name, 'EntityName')

  const ff = Path.normalize(__dirname + '/../../../src/cmp/java/fragment/')

  // Entity classes go to the entity/ folder; the file name must match the
  // public class name (Java requirement).
  Folder({ name: 'entity' }, () => {

    File({ name: cls + '.' + target.ext }, () => {

      const opnames = Object.keys(entity.op || {})

      // For each CRUD op: if the spec defines it, splice in the real
      // implementation. Otherwise emit a stub that satisfies the SdkEntity
      // interface (so the package compiles) but errors at runtime if the
      // caller invokes an unsupported op.
      const opfrags =
        (['load', 'list', 'create', 'update', 'remove']
          .reduce((a: any, opname: string) =>
          (a['// #' + camelify(opname) + 'Op'] =
            !opnames.includes(opname) ?
              ({ indent }: any) => {
                Content({ indent }, `  @Override
  public Object ${opname}(Map<String, Object> req, Map<String, Object> ctrl) {
    throw Helpers.unsupportedOp("${opname}", this.name);
  }
`)
              } :
              ({ indent }: any) => {
                EntityOperation({ ff, opname, indent, entity, entrep, javapackage, cls })
              }, a), {}))

      Fragment({
        from: ff + 'Entity.fragment.java',
        replace: {
          ...entrep,
          JAVAPACKAGE: javapackage,
          ProjectName: model.const.Name,
          EntityName: entity.Name,
          entityname: entity.name,

          // Class tokens are decoupled from the EntityName data-type token
          // so the class can be renamed independently.
          EntyClass: cls,

          '#Entity-Hook': ({ name, indent }: any) =>
            Content({ indent }, `utility.featureHook.apply(ctx, "${name}");`),

          ...opfrags,
        }
      })

    })
  })
})



export {
  Entity
}
