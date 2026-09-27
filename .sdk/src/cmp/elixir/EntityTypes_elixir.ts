


import {
  cmp, each, names,
  File, Folder, Content,
} from '@voxgig/sdkgen'

import { opRequestShape, OP_SUFFIX, warnEntityTypeCollisions, deriveEntityNames } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { elixirType } from './utility_elixir'


function elixirOpTypeName(ename: string, opname: string): string {
  return ename + '_' + opname + '_' + (OP_SUFFIX[opname] || 'Match').toLowerCase()
}


function emitType(
  typeName: string,
  doc: string,
  members: Array<{ name: string, type: unknown, optional: boolean }>,
): void {
  let block = `  @typedoc """\n  ${doc}\n`

  if (0 < members.length) {
    block += `\n  Members:\n`
    members.forEach((m) => {
      const req = m.optional ? ' (optional)' : ' (required)'
      block += `    * \`"${m.name}"\` — ${elixirType(m.type)}${req}\n`
    })
  }

  block += `  """\n  @type ${typeName} :: %{optional(String.t()) => any()}\n\n`

  Content(block)
}


const LANG = 'elixir'


const EntityTypes = cmp(function EntityTypes(props: any) {
  const { model, log } = props.ctx$

  const Name = model.const.Name
  const app = model.const.name.toLowerCase()

  const entity = getModelPath(model, `main.${KIT}.entity`, { only_active: false, required: false })
  // Emit for EVERY entity that gets an entity module: the consumer scaffold
  // (create-sdkgen Root.ts) iterates entities WITHOUT an active filter, and
  // each generated module carries @specs referencing its Types aliases, so an
  // alias is required for each or the project won't compile. Filter on `name`
  // (always present), NOT `active` — parity with the go emitter's fix.
  const entityList = deriveEntityNames(entity)
  // Derive the PascalCase Name up-front — it is set LAZILY by names(), so an
  // entity not yet named would otherwise read `Name = undefined` below.

  warnEntityTypeCollisions(entity, log, LANG)

  Folder({ name: 'lib' }, () => {
    File({ name: app + '_types.ex' }, () => {

      Content(`# Typed models for the ${Name} SDK.
#
# GENERATED from the API model: main.${KIT}.entity.<e>.fields{} and per-op
# params (op.<name>.points[].g.params[]). Member types come from the
# canonical type sentinels. The SDK carries data as string-keyed struct value
# nodes, so each alias is an open string-keyed map; the @typedoc member lists
# document the concrete shapes. Do not edit by hand.

defmodule ${Name}.Types do
  @moduledoc """
  Documented shapes for the ${Name} SDK entities and operation payloads.

  Every alias resolves to an open string-keyed map because the SDK carries
  data as string-keyed struct value nodes; consult each type's member list for
  the concrete field/param types.
  """

`)

      entityList.forEach((ent: any) => {
        const EName = ent.Name
        const ename = ent.name
        const fields = (ent.fields ? each(ent.fields) : [])
          .filter((f: any) => f.a !== false)

        emitType(
          ename,
          `${EName} entity data model.`,
          fields.map((f: any) => ({ name: f.n, type: f.t, optional: false === f.r })),
        )

        const ops = ent.op || {}
        ;['load', 'list', 'create', 'update', 'remove'].forEach((opname: string) => {
          if (null == ops[opname]) {
            return
          }

          const typeName = elixirOpTypeName(ename, opname)
          const { items } = opRequestShape(ent, opname)

          emitType(
            typeName,
            `Request payload for ${EName} ${opname}.`,
            items,
          )
        })
      })

      Content(`end
`)
    })
  })
})


export {
  EntityTypes,
}
