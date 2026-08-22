
import * as Path from 'node:path'

import {
  cmp, camelify,
  File, Content, Folder, Fragment,
  entityClassName, entityCollection,
} from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath
} from '@voxgig/apidef'

import { EntityOperation } from './EntityOperation_rust'
import { rustVarName } from './utility_rust'


const Entity = cmp(function Entity(props: any) {
  const { model, stdrep } = props.ctx$
  const { target, entity } = props

  // Collision-free entity CLASS name (see entityClassName): normally
  // `<Name>Entity`, but disambiguated when it would clash with another
  // entity's data-type name.
  const entityColl = entityCollection(model)
  const cls = entityClassName(entity, entityColl)

  const entrep = {
    ...stdrep,
  }

  const ff = Path.normalize(__dirname + '/../../../src/cmp/rust/fragment/')

  // Entity files go to entity/ as one module per entity.
  Folder({ name: 'entity' }, () => {

    File({ name: rustVarName(entity.name) + '.' + target.ext }, () => {

      const opnames = Object.keys(entity.op || {})

      // For each CRUD op: if the spec defines it, splice in the real
      // implementation. Otherwise emit a stub that satisfies the static
      // ProjectNameEntity trait (so the crate compiles) but errors at
      // runtime if the caller invokes an unsupported op.
      // Tag-form keys (`#LoadOp`) match the marker line `// #LoadOp` and
      // capture its indent, so the spliced method nests inside the impl.
      const opfrags =
        (['load', 'list', 'create', 'update', 'remove']
          .reduce((a: any, opname: string) =>
          (a['#' + camelify(opname) + 'Op'] =
            !opnames.includes(opname) ?
              ({ indent }: any) => {
                const arg = ('create' === opname || 'update' === opname) ?
                  'reqdata' : 'reqmatch'
                // The stub mirrors the real signature: ops resolve to the
                // ENTITY (`list` to a vector of them), so an unsupported op
                // has to declare the same return type to satisfy the trait.
                const ret = 'list' === opname ? 'Vec<Rc<Self>>' : 'Rc<Self>'
                Content({ indent }, `fn ${opname}(self: &Rc<Self>, _${arg}: Value, _ctrl: Value) -> Result<${ret}, ${model.const.Name}Error> {
    Err(crate::core::helpers::unsupported_op("${opname}", &self.name))
}
`)
              } :
              ({ indent }: any) => {
                EntityOperation({ ff, opname, indent, entity, entrep, cls })
              }, a), {}))

      Fragment({
        from: ff + 'Entity.fragment.rs',
        replace: {
          ...entrep,
          ProjectName: model.const.Name,
          EntityName: entity.Name,
          entityname: entity.name,

          // Class/constructor tokens are decoupled from the EntityName
          // data-type token so the class can be renamed independently.
          EntyClass: cls,

          // Matches every `// #<Stage>-Hook` marker in the fragment (all of
          // them sit inside run_op, where `ctx` is the operation context).
          '#Entity-Hook': ({ name, indent }: any) =>
            Content({ indent }, `self.utility.feature_hook(ctx, "${name}");`),

          ...opfrags,
        }
      })

    })
  })
})



export {
  Entity
}
