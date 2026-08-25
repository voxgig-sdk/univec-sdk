
// Typed-model generator (Swift target). Port of EntityTypes_rust.ts /
// EntityTypes_go.ts.
//
// Reads main.<KIT>.entity.<e>.fields[] and per-op params
// (op.<name>.points[].args.params[]) and emits one file,
// Sources/ProjectNameSDK/entity/<Name>Types.swift, with a `struct <Name>` per
// entity plus a request/match struct per active op. Field/param sentinels
// ($STRING, $INTEGER, ...) map to Swift types via the SHARED canonToType
// 'swift' column (the single source of truth per language — do not keep a
// local table here).
//
// DESIGN NOTE: the Swift runtime is fully DYNAMIC — every op takes and returns
// the vendored `Value` enum (throws on error) and the op fragments emit no
// typed wrappers. These typed models are therefore DOCUMENTARY: they mirror the
// entity/op shapes for reference and IDE support, but are not wired into the op
// signatures. They compile as part of the SwiftPM target (every .swift under
// Sources/ProjectNameSDK is built) so they stay in sync with the model.
//   * Optional (req:false) member -> `T?`.
//   * Unknown/missing sentinel -> the dynamic `Value` (never fails), matching
//     the runtime's open shape.

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


// Emit a `struct <typeName>` from {name, type, optional} items, dropping
// duplicate Swift identifiers (two model names can collapse to one ident). An
// empty struct is a valid, zero-property shape.
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
  // Emit for every entity that gets an entity file (filter on `name`, always
  // present; derive `Name` here so the struct set is deterministic — parity
  // with the rust/go emitter's fix).
  const entityList = deriveEntityNames(entity)

  // Surface duplicate generated type names (two entities with the same
  // PascalCase Name) — they would redeclare a type in statically-typed
  // targets. Detection only; renaming is a model-level decision.
  warnEntityTypeCollisions(entity, log, LANG)

  Folder({ name: 'Sources' }, () => {
    Folder({ name: swiftTargetDir(model) }, () => {
      Folder({ name: 'entity' }, () => {

        File({ name: model.const.Name + 'Types.' + target.ext }, () => {

          Content(`// Typed models for the ${model.const.Name} SDK.
//
// GENERATED from the API model: main.${KIT}.entity.<e>.fields[] and per-op
// params (op.<name>.points[].args.params[]). Field/param types are mapped
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
              .filter((f: any) => f.active !== false)

            // Entity data model: one property per field. req:false -> optional.
            //
            // Swift has no intra-module namespacing, so a spec schema named
            // after one of our own runtime types (e.g. `Response`) would be a
            // redeclaration and fail the build. swiftSafeTypeName appends
            // `Type` on collision only — `Response` -> `ResponseType` — so
            // non-colliding SDKs generate byte-identical output to before.
            const TypeName = swiftSafeTypeName(Name)
            emitStruct(
              `/// ${TypeName} is the typed data model for the ${ent.name} entity.`,
              TypeName,
              fields.map((f: any) => ({ name: f.name, type: f.type, optional: false === f.req }))
            )

            // Per active op: a request/match struct. Members and their
            // optionality come from the shared partiality policy
            // (opRequestShape).
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
