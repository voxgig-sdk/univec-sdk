
import * as Path from 'node:path'

import {
  cmp, camelify,
  File, Folder, Fragment,
} from '@voxgig/sdkgen'


import { EntityOperation } from './EntityOperation_elixir'


const Entity = cmp(function Entity(props: any) {
  const { model, stdrep } = props.ctx$
  const { target, entity } = props

  const Name = model.const.Name
  const entrep = { ...stdrep }

  const ff = Path.normalize(__dirname + '/../../../src/cmp/elixir/fragment/')

  Folder({ name: 'lib' }, () => {
    Folder({ name: 'entity' }, () => {
      File({ name: entity.name + '_entity.' + target.ext }, () => {

        const opnames = Object.keys(entity.op || {})

        const opfrags =
          (['load', 'list', 'create', 'update', 'remove']
            .reduce((a: any, opname: string) =>
            (a['# #' + camelify(opname) + 'Op'] =
              !opnames.includes(opname) ? '' : (_slot: any) => {
                EntityOperation({ ff, opname, entity, entrep })
              }, a), {}))

        Fragment({
          from: ff + 'Entity.fragment.ex',
          replace: {
            ...entrep,
            ProjectName: Name,
            EntityName: entity.Name,
            entityname: entity.name,
            ...opfrags,
          }
        })
      })
    })
  })
})


export {
  Entity
}
