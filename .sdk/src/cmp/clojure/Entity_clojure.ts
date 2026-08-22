
import * as Path from 'node:path'

import {
  cmp, camelify,
  File, Folder, Fragment,
} from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath
} from '@voxgig/apidef'

import { EntityOperation } from './EntityOperation_clojure'


const Entity = cmp(function Entity(props: any) {
  const { model, stdrep } = props.ctx$
  const { target, entity } = props

  const entrep = {
    ...stdrep,
  }

  const ff = Path.normalize(__dirname + '/../../../src/cmp/clojure/fragment/')

  // Entity files go to src/sdk/entity/<name>.clj (ns sdk.entity.<name>).
  Folder({ name: 'src' }, () => {
    Folder({ name: 'sdk' }, () => {
      Folder({ name: 'entity' }, () => {

        File({ name: entity.name + '.' + target.ext }, () => {

          const opnames = Object.keys(entity.op || {})

          // For each CRUD op: splice the real implementation when the spec
          // defines it; otherwise leave the slot empty (the fn is simply not
          // defined — callers of an unsupported op get an undefined-var error,
          // matching the dynamic-language donors).
          const opfrags =
            (['load', 'list', 'create', 'update', 'remove']
              .reduce((a: any, opname: string) =>
              (a['; #' + camelify(opname) + 'Op'] =
                !opnames.includes(opname) ? '' : ({ indent }: any) => {
                  EntityOperation({ ff, opname, indent, entity, entrep })
                }, a), {}))

          Fragment({
            from: ff + 'Entity.fragment.clj',
            replace: {
              ...entrep,
              ProjectName: model.const.Name,
              EntityName: entity.Name,
              entityname: entity.name,

              // Feature-hook markers. jostraca's built-in `#Name-Tag` pattern
              // is hardcoded to `//` comments, so Clojure's `; #<Name>-Hook`
              // marker lines never match it and the pipeline hooks would be
              // silently dropped. Match the `;`-comment form explicitly.
              '/(?<indent>[ \\t]*);+[ \\t]*#(?<name>[A-Za-z0-9]+)-Hook[ \\t]*\\n?/':
                ({ name, indent }: any) =>
                  `${indent}(core/feature-hook ctx "${name}")\n`,

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
