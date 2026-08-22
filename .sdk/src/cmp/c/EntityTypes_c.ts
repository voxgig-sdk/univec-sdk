

// Typed-model generator (C target). Port of EntityTypes_rust.ts / _go.ts.
//
// Reads main.<KIT>.entity.<e>.fields[] and per-op params
// (op.<name>.points[].args.params[]) and emits one header, entity/types.h,
// with a C `typedef struct { ... } <Name>;` per entity plus a request/match
// struct per active op. Field/param sentinels ($STRING, $INTEGER, ...) map to
// C types via the SHARED canonToType 'c' column (the single source of truth
// per language — do not keep a local table here).
//
// DESIGN NOTE (C specifics vs the rust/go reference):
//   * The C runtime is fully DYNAMIC: every op takes and returns the vendored
//     `voxgig_value*` (with a trailing PNError** out-param), and the entity
//     fragments emit no typed wrappers. These structs are therefore
//     DOCUMENTARY — they mirror the entity/op shapes for reference and IDE
//     support, but nothing in the runtime consumes them. types.h is a
//     standalone header (guarded, includes sdk.h for the primitive types); it
//     is not #included by any generated .c, so it never affects the build.
//   * C has no Option<T> / optional struct members: a `req:false` field is
//     still declared, with a trailing `// optional` marker. Absence is
//     represented at runtime by the value simply not being present in the map.
//   * Member names are snake_case + keyword-safe via cVarName; duplicate
//     idents are dropped so a struct never declares the same member twice.
//
// Keep the SAME type-name scheme as every other language: <Name>,
// <Name>LoadMatch, <Name>ListMatch, <Name>CreateData, <Name>UpdateData,
// <Name>RemoveMatch.

import {
  cmp, each,
  File, Content, Folder,
} from '@voxgig/sdkgen'

import { canonToType, opTypeName, opRequestShape, warnEntityTypeCollisions , deriveEntityNames } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { cVarName } from './utility_c'


const LANG = 'c'


// One C struct member line. `optional` -> a trailing marker (C has no
// Option<T>). Member names are snake_case + keyword-safe via cVarName.
function memberLine(name: string, sentinel: any, optional: boolean): string {
  const ct = canonToType(sentinel, LANG)
  const sep = ct.endsWith('*') ? '' : ' '
  return `  ${ct}${sep}${cVarName(name)};${optional ? '  // optional' : ''}\n`
}


// Emit a `typedef struct { ... } <typeName>;` from {name, type, optional}
// items, dropping duplicate C identifiers (two model names can collapse to
// one ident). An empty shape gets a placeholder member (a struct with no
// members is not valid ISO C).
function emitStruct(comment: string, typeName: string, items: any[]): void {
  Content(`${comment}
typedef struct {
`)
  const seen = new Set<string>()
  let count = 0
  items.forEach((it: any) => {
    if (null == it || null == it.name) return
    const ident = cVarName(it.name)
    if (seen.has(ident)) return
    seen.add(ident)
    Content(memberLine(it.name, it.type, !!it.optional))
    count++
  })
  if (0 === count) {
    Content(`  char _unused;  // placeholder: no modelled members
`)
  }
  Content(`} ${typeName};

`)
}


const EntityTypes = cmp(function EntityTypes(props: any) {
  const { model, log } = props.ctx$

  // only_active:false — getModelPath DROPS active:false entries by default,
  // but the consumer scaffold (create-sdkgen Root.ts) iterates the RAW entity
  // collection, so inactive entities still get generated entity code that
  // references these typed names. The typed model must cover them too.
  const entity = getModelPath(model, `main.${KIT}.entity`, { only_active: false, required: false })
  // Emit for every entity that gets an entity file (filter on `name`, always
  // present; derive `Name` here so the struct set is deterministic — parity
  // with the go/rust emitters' fix).
  const entityList = deriveEntityNames(entity)

  // Surface duplicate generated type names (two entities with the same
  // PascalCase Name) — they would redeclare a type in statically-typed
  // targets. Detection only; renaming is a model-level decision.
  warnEntityTypeCollisions(entity, log, LANG)

  const guard = String(model.const.Name).toUpperCase().replace(/[^A-Z0-9_]/g, '_') + '_ENTITY_TYPES_H'

  Folder({ name: 'entity' }, () => {

    File({ name: 'types.h' }, () => {

      Content(`// Typed models for the ${model.const.Name} SDK.
//
// GENERATED from the API model: main.${KIT}.entity.<e>.fields[] and per-op
// params (op.<name>.points[].args.params[]). Field/param types are mapped
// from the canonical type sentinels. Do not edit by hand.
//
// These are DOCUMENTARY: the SDK runtime is dynamic (ops take/return
// \`voxgig_value*\`), so nothing consumes these structs yet — they mirror the
// entity/op shapes for reference and IDE support. This header is standalone
// and is not #included by any generated .c.

#ifndef ${guard}
#define ${guard}

#include "sdk.h"

`)

      entityList.forEach((ent: any) => {
        const Name = ent.Name
        const fields = (ent.fields ? each(ent.fields) : [])
          .filter((f: any) => f.active !== false)

        // Entity data model: one member per model field. req:false -> optional.
        emitStruct(
          `// ${Name} is the typed data model for the ${ent.name} entity.`,
          Name,
          fields.map((f: any) => ({ name: f.name, type: f.type, optional: false === f.req }))
        )

        // Per active op: a request/match struct. Members and their optionality
        // come from the shared partiality policy (opRequestShape).
        const ops = ent.op || {}
        ;['load', 'list', 'create', 'update', 'remove'].forEach((opname: string) => {
          if (null == ops[opname]) {
            return
          }

          const typeName = opTypeName(Name, opname)
          const { items } = opRequestShape(ent, opname)

          emitStruct(
            `// ${typeName} is the typed request payload for ${Name}.${opname}.`,
            typeName,
            items
          )
        })
      })

      Content(`#endif // ${guard}
`)
    })
  })
})


export {
  EntityTypes,
}
