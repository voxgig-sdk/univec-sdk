
// Typed-model generator (Dart target). Port of EntityTypes_ts.ts.
//
// Reads main.<KIT>.entity.<e>.fields[] and per-op params
// (op.<name>.points[].args.params[]) and emits one file,
// lib/<Sdk>Types.dart, with a Dart class per active entity plus a
// request/match class per active op. Field/param sentinels ($STRING,
// $INTEGER, ...) map to Dart types via the SHARED canonToType 'dart' column
// (the single source of truth per language — do not keep a local table
// here); the doc-comment sentinel key comes from the shared canonKey helper
// so the source of truth (@voxgig/apidef VALID_CANON) is respected.
//
// TYPE CHOICE: plain classes with nullable fields + fromMap/toMap. The
// generated ops accept/return runtime maps (Dart has no structural typing),
// so these classes are the documented, convertible view of those maps —
// mirroring the Python target's TypedDict approach at the level Dart
// allows. Keep the SAME type-name scheme as every other language: <Name>,
// <Name>LoadMatch, <Name>ListMatch, <Name>CreateData, <Name>UpdateData,
// <Name>RemoveMatch.

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


// A name usable as a Dart field (valid identifier, not a keyword, public).
function dartIdent(name: string): boolean {
  return /^[A-Za-z][A-Za-z0-9_]*$/.test(name) && !DART_KEYWORDS.has(name)
}


// Emit a Dart data class from a list of {name, type, optional} items. All
// fields are nullable (`optional` is documented) since the runtime passes
// partial maps; fromMap is lenient (mismatched value types become null). An
// item whose name is not a legal identifier is skipped (WITH a warning — the
// key stays reachable via the runtime map, but its absence from the typed
// model should be visible, not silent).
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

  // Surface duplicate generated type names (two entities with the same
  // PascalCase Name) — they would redeclare a type in statically-typed
  // targets. Detection only; renaming is a model-level decision.
  warnEntityTypeCollisions(entity, log, LANG)

  File({ name: model.const.Name + 'Types.' + target.ext }, () => {

    Content(`// Typed models for the ${model.const.Name} SDK.
//
// GENERATED from the API model: main.${KIT}.entity.<e>.fields[] and per-op
// params (op.<name>.points[].args.params[]). Field/param types come from the
// canonical type sentinels (source of truth: @voxgig/apidef VALID_CANON).
// Do not edit by hand.
//
// The operation pipeline passes plain maps; these classes are the typed,
// convertible view: \`${model.const.Name}.fromMap(ent.data())\` / \`model.toMap()\`.

`)

    entityList.forEach((ent: any) => {
      const Name = ent.Name
      const fields = (ent.fields ? each(ent.fields) : [])
        .filter((f: any) => f.active !== false)

      // Entity data model: one field per model field, `req:false` -> optional.
      emitClass(Name, fields.map((f: any) => ({
        name: f.name,
        type: f.type,
        optional: false === f.req,
      })), log)

      // Per active op: a request/match type. The members and each member's
      // required/optional decision come from the shared partiality policy
      // (opRequestShape); this file only renders them as a Dart class.
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
