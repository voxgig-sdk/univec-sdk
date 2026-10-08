
import * as Path from 'node:path'

import {
  cmp, camelify,
  File, Folder, Fragment,
} from '@voxgig/sdkgen'


import { EntityOperation } from './EntityOperation_elixir'


const OPS = ['load', 'list', 'create', 'update', 'patch', 'remove']


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
          (OPS
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
            '# #Aliases': aliases(props.ctx$.fs(), ff, Name, opnames),
            ...opfrags,
          }
        })
      })
    })
  })
})


// Only what the emitted operations use: elixir warns on an unused alias.
function aliases(fs: any, ff: string, Name: string, opnames: string[]): string {
  const optext = OPS.filter((opname) => opnames.includes(opname))
    .map((opname) => String(fs.readFileSync(
      ff + 'Entity' + camelify(opname) + 'Op.fragment.ex', 'utf8')))
    .join('\n')
  const uses = (name: string) => new RegExp('\\b' + name + '\\.').test(optext)
  const core = ['EntityBase', ...['Context', 'Pipeline'].filter(uses)]

  return [
    ...(uses('S') ? ['alias Voxgig.Struct, as: S'] : []),
    ...(uses('H') ? ['alias ' + Name + '.Helpers, as: H'] : []),
    'alias ' + Name + (1 === core.length ? '.' + core[0] : '.{' + core.join(', ') + '}'),
  ].join('\n  ')
}


export {
  Entity
}
