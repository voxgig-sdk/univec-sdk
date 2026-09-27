


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


function cppIdent(name: string): boolean {
  return /^[A-Za-z_][A-Za-z0-9_]*$/.test(name)
}


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

  warnEntityTypeCollisions(entity, log, LANG)

  const guard = 'SDK_' + model.const.Name.toUpperCase().replace(/[^A-Z0-9]/g, '_') + '_TYPES_HPP'

  File({ name: model.const.Name.toLowerCase() + '_types.' + ext }, () => {

    Content(`// Typed reference models for the ${model.const.Name} SDK (C++).
//
// GENERATED from the API model: main.${KIT}.entity.<e>.fields{} and per-op
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
        .filter((f: any) => f.a !== false)

      emitStruct(Name, fields.map((f: any) => ({
        name: f.n, type: f.t, optional: false === f.r,
      })), log)

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
