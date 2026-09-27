

import {
  cmp, each,
  File, Content, Folder,
} from '@voxgig/sdkgen'

import { canonToType, opTypeName, opRequestShape, warnEntityTypeCollisions , deriveEntityNames, swiftSafeTypeName } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { swiftVarName , swiftTargetDir, swiftTestDir } from './utility_swift'


const LANG = 'swift'


// One Swift struct property line. `optional` -> `T?`. Property names are
// keyword-safe + lowerCamelCase via swiftVarName; duplicates are dropped by the
// caller so a struct never declares the same property twice.
function propLine(name: string, sentinel: any, optional: boolean): string {
  const st = canonToType(sentinel, LANG)
  const typ = optional ? `${st}?` : st
  return `  public var ${swiftVarName(name)}: ${typ}\n`
}


function emitStruct(comment: string, typeName: string, items: any[]): void {
  Content(`${comment}
public struct ${typeName} {
`)
  const seen = new Set<string>()
  items.forEach((it: any) => {
    if (null == it || null == it.name) return
    const ident = swiftVarName(it.name)
    if (seen.has(ident)) return
    seen.add(ident)
    Content(propLine(it.name, it.type, !!it.optional))
  })
  Content(`}

`)
}


const EntityTypes = cmp(function EntityTypes(props: any) {
  const { target } = props
  const { model, log } = props.ctx$

  // only_active:false — getModelPath DROPS active:false entries by default,
  // but the consumer scaffold (create-sdkgen Root.ts) iterates the RAW entity
  // collection, so inactive entities still get generated entity code that
  // references these typed names. The typed model must cover them too.
  const entity = getModelPath(model, `main.${KIT}.entity`, { only_active: false, required: false })
  const entityList = deriveEntityNames(entity)

  warnEntityTypeCollisions(entity, log, LANG)

  Folder({ name: 'Sources' }, () => {
    Folder({ name: swiftTargetDir(model) }, () => {
      Folder({ name: 'entity' }, () => {

        File({ name: model.const.Name + 'Types.' + target.ext }, () => {

          Content(`// Typed models for the ${model.const.Name} SDK.
//
// GENERATED from the API model: main.${KIT}.entity.<e>.fields{} and per-op
// params (op.<name>.points[].g.params[]). Field/param types are mapped
// from the canonical type sentinels. Do not edit by hand.
//
// These are DOCUMENTARY: the SDK runtime is dynamic (ops take/return the
// \`Value\` enum), so nothing consumes these structs yet — they mirror the
// entity/op shapes for reference and IDE support.

import Foundation

`)

          entityList.forEach((ent: any) => {
            const Name = ent.Name
            const fields = (ent.fields ? each(ent.fields) : [])
              .filter((f: any) => f.a !== false)

            const TypeName = swiftSafeTypeName(Name)
            emitStruct(
              `/// ${TypeName} is the typed data model for the ${ent.name} entity.`,
              TypeName,
              fields.map((f: any) => ({ name: f.n, type: f.t, optional: false === f.r }))
            )

            const ops = ent.op || {}
              ;['load', 'list', 'create', 'update', 'remove'].forEach((opname: string) => {
                if (null == ops[opname]) {
                  return
                }

                const typeName = opTypeName(Name, opname)
                const { items } = opRequestShape(ent, opname)

                emitStruct(
                  `/// ${typeName} is the typed request payload for ${Name}.${opname}.`,
                  typeName,
                  items
                )
              })
          })
        })
      })
    })
  })
})


export {
  EntityTypes,
}
