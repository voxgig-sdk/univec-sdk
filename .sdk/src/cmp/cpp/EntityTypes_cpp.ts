

// Typed-model generator (C++ target). Port of EntityTypes_ts.ts / _py.ts.
//
// The C++ SDK runtime is fully DYNAMIC: every op takes and returns the
// JSON-like sdk::Value, so — unlike a statically typed target — there are no
// generated structs the runtime consumes. This module emits a DOCUMENTATION
// header, <sdk>_types.hpp, describing the shape of each entity and its per-op
// request/match payloads as plain C++ structs in a dedicated `sdk::types`
// namespace. They are convenience/reference types a consumer MAY use to model
// payloads; the SDK itself neither includes nor requires this header, so it is
// safe (it cannot affect the runtime or the test build).
//
// Field/param sentinels ($STRING, $INTEGER, ...) map to concrete C++ types via
// the SHARED canonToType 'cpp' column (the single source of truth per language
// — do not keep a local table here). Array surfaces as std::vector<Value>,
// object as std::map<std::string, Value>, and any/null/unknown as the dynamic
// sdk::Value. Optional (req:false) members are marked with a trailing
// `// optional` comment — a struct member is always present in C++, so
// key-optionality is documented rather than encoded.
//
// Keep the SAME type-name scheme as every other language: <Name>,
// <Name>LoadMatch, <Name>ListMatch, <Name>CreateData, <Name>UpdateData,
// <Name>RemoveMatch (via the shared opTypeName helper).

import {
  cmp, each, names,
  File, Content,
  canonToType, opTypeName, opRequestShape, warnEntityTypeCollisions,
  deriveEntityNames,
} from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'


const LANG = 'cpp'


// A valid C++ identifier for a struct member; non-identifier field names have
// no safe struct-member rendering, so they are skipped (still reachable via the
// runtime Value map).
function cppIdent(name: string): boolean {
  return /^[A-Za-z_][A-Za-z0-9_]*$/.test(name)
}


// Emit a struct named `typeName` from a list of {name, type, optional} items.
// An item whose name is not a legal identifier is skipped (WITH a warning —
// the key stays reachable via the runtime Value map, but its absence from the
// typed model should be visible, not silent).
function emitStruct(typeName: string, items: any[], log?: any): void {
  const usable = items.filter((it: any) => it && null != it.name && cppIdent(it.name))

  items.forEach((it: any) => {
    if (it && null != it.name && !cppIdent(it.name) && log && log.warn) {
      log.warn({
        point: 'entity-types-skip-field', typeName, field: it.name,
        note: `cpp: field "${it.name}" of ${typeName} has no legal C++ ` +
          `identifier form; omitted from the typed model (still reachable ` +
          `via the runtime Value map)`,
      })
    }
  })

  if (0 === usable.length) {
    Content(`struct ${typeName} {};

`)
    return
  }

  Content(`struct ${typeName} {
`)
  usable.forEach((it: any) => {
    const opt = it.optional ? '  // optional' : ''
    Content(`  ${canonToType(it.type, LANG)} ${it.name};${opt}
`)
  })
  Content(`};

`)
}


const EntityTypes = cmp(function EntityTypes(props: any) {
  const { model, log } = props.ctx$
  const target = props.target || {}
  const ext = target.ext || 'hpp'

  // only_active:false — getModelPath DROPS active:false entries by default,
  // but the consumer scaffold (create-sdkgen Root.ts) iterates the RAW entity
  // collection, so inactive entities still get generated entity code that
  // references these typed names. The typed model must cover them too.
  const entity = getModelPath(model, `main.${KIT}.entity`, { only_active: false, required: false })
  // Emit for EVERY entity that gets generated entity code: the consumer
  // scaffold (create-sdkgen Root.ts) iterates entities WITHOUT an active
  // filter, so inactive entities still get class files referencing these
  // typed names. Filter on `name` (always present), NOT `active` — parity
  // with the go emitter's fix.
  const entityList = deriveEntityNames(entity)
  // Derive the PascalCase Name up-front — it is set LAZILY by names().

  // Surface duplicate generated type names (two entities with the same
  // PascalCase Name) — they would redeclare a type in statically-typed
  // targets. Detection only; renaming is a model-level decision.
  warnEntityTypeCollisions(entity, log, LANG)

  const guard = 'SDK_' + model.const.Name.toUpperCase().replace(/[^A-Z0-9]/g, '_') + '_TYPES_HPP'

  File({ name: model.const.Name.toLowerCase() + '_types.' + ext }, () => {

    Content(`// Typed reference models for the ${model.const.Name} SDK (C++).
//
// GENERATED from the API model: main.${KIT}.entity.<e>.fields[] and per-op
// params. The C++ SDK runtime is Value-based, so these structs are
// DOCUMENTATION / convenience types only — the SDK neither includes nor
// requires this header. Array fields surface as std::vector<Value>, object
// fields as std::map<std::string, Value>, and any/null fields as sdk::Value.
// Optional (req:false) members are flagged with a trailing "// optional"
// comment. Do not edit by hand.

#ifndef ${guard}
#define ${guard}

#include <cstdint>
#include <map>
#include <string>
#include <vector>

#include "core/types.hpp"

namespace sdk {
namespace types {

`)

    entityList.forEach((ent: any) => {
      const Name = ent.Name
      const fields = (ent.fields ? each(ent.fields) : [])
        .filter((f: any) => f.active !== false)

      // Entity data model: one member per field, `req:false` -> optional.
      emitStruct(Name, fields.map((f: any) => ({
        name: f.name, type: f.type, optional: false === f.req,
      })), log)

      // Per active op: a request/match type. Members and their optionality
      // come from the shared partiality policy (opRequestShape).
      const ops = ent.op || {}
      ;['load', 'list', 'create', 'update', 'remove'].forEach((opname: string) => {
        if (null == ops[opname]) {
          return
        }
        const typeName = opTypeName(Name, opname)
        const { items } = opRequestShape(ent, opname)
        emitStruct(typeName, items, log)
      })
    })

    Content(`} // namespace types
} // namespace sdk

#endif // ${guard}
`)
  })
})


export {
  EntityTypes,
}
