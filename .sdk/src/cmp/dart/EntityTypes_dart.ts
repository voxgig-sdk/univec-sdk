

import {
  cmp, each, names,
  File, Content,
} from '@voxgig/sdkgen'

import { canonKey, canonToType, opTypeName, opRequestShape, warnEntityTypeCollisions, deriveEntityNames } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'


const LANG = 'dart'


// Dart reserved words that cannot be used as field names.
const DART_KEYWORDS = new Set([
  'assert', 'break', 'case', 'catch', 'class', 'const', 'continue',
  'default', 'do', 'else', 'enum', 'extends', 'false', 'final', 'finally',
  'for', 'if', 'in', 'is', 'new', 'null', 'rethrow', 'return', 'super',
  'switch', 'this', 'throw', 'true', 'try', 'var', 'void', 'while', 'with',
])


function dartIdent(name: string): boolean {
  return /^[A-Za-z][A-Za-z0-9_]*$/.test(name) && !DART_KEYWORDS.has(name)
}


function emitClass(typeName: string, items: any[], log?: any): void {
  const usable = items.filter((it: any) => it && null != it.name && dartIdent(it.name))

  items.forEach((it: any) => {
    if (it && null != it.name && !dartIdent(it.name) && log && log.warn) {
      log.warn({
        point: 'entity-types-skip-field', typeName, field: it.name,
        note: `dart: field "${it.name}" of ${typeName} has no legal Dart ` +
          `identifier form; omitted from the typed model (still reachable ` +
          `via the runtime map)`,
      })
    }
  })

  Content(`class ${typeName} {
`)
  usable.forEach((it: any) => {
    const base = canonToType(it.type, LANG)
    const t = 'dynamic' === base ? 'dynamic' : base + '?'
    const req = it.optional ? '' : ' (required at the API)'
    Content(`  /// ${canonKey(it.type) || 'ANY'}${req}
  ${t} ${it.name};
`)
  })

  if (0 === usable.length) {
    Content(`  ${typeName}();

  factory ${typeName}.fromMap(Map<String, dynamic> m) => ${typeName}();

  Map<String, dynamic> toMap() => <String, dynamic>{};
`)
  }
  else {
    Content(`
  ${typeName}({
`)
    usable.forEach((it: any) => {
      Content(`    this.${it.name},
`)
    })
    Content(`  });

  factory ${typeName}.fromMap(Map<String, dynamic> m) => ${typeName}(
`)
    usable.forEach((it: any) => {
      const base = canonToType(it.type, LANG)
      if ('dynamic' === base) {
        Content(`        ${it.name}: m['${it.name}'],
`)
      }
      else {
        Content(`        ${it.name}: m['${it.name}'] is ${base} ? m['${it.name}'] : null,
`)
      }
    })
    Content(`      );

  Map<String, dynamic> toMap() {
    final m = <String, dynamic>{};
`)
    usable.forEach((it: any) => {
      Content(`    if (null != ${it.name}) {
      m['${it.name}'] = ${it.name};
    }
`)
    })
    Content(`    return m;
  }
`)
  }

  Content(`}

`)
}


const EntityTypes = cmp(function EntityTypes(props: any) {
  const { model, log } = props.ctx$
  const { target } = props

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
  // Derive the PascalCase Name up-front — it is set LAZILY by names(), so an
  // entity not yet named (e.g. a fieldless placeholder) would otherwise read
  // `Name = undefined` below. Parity with the go emitter's fix.

  warnEntityTypeCollisions(entity, log, LANG)

  File({ name: model.const.Name + 'Types.' + target.ext }, () => {

    Content(`// Typed models for the ${model.const.Name} SDK.
//
// GENERATED from the API model: main.${KIT}.entity.<e>.fields{} and per-op
// params (op.<name>.points[].g.params[]). Field/param types come from the
// canonical type sentinels (source of truth: @voxgig/apidef VALID_CANON).
// Do not edit by hand.
//
// The operation pipeline passes plain maps; these classes are the typed,
// convertible view: \`${model.const.Name}.fromMap(ent.data())\` / \`model.toMap()\`.

`)

    entityList.forEach((ent: any) => {
      const Name = ent.Name
      const fields = (ent.fields ? each(ent.fields) : [])
        .filter((f: any) => f.a !== false)

      emitClass(Name, fields.map((f: any) => ({
        name: f.n,
        type: f.t,
        optional: false === f.r,
      })), log)

      const ops = ent.op || {}
      ;['load', 'list', 'create', 'update', 'remove'].forEach((opname: string) => {
        if (null == ops[opname]) {
          return
        }

        const typeName = opTypeName(Name, opname)
        const { items } = opRequestShape(ent, opname)

        emitClass(typeName, items, log)
      })
    })
  })
})


export {
  EntityTypes,
}
