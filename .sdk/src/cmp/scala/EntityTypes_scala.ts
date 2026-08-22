

// Typed-model generator (Scala target). Port of EntityTypes_java.ts /
// EntityTypes_py.ts.
//
// Reads main.<KIT>.entity.<e>.fields[] and per-op params
// (op.<name>.points[].args.params[]) and emits ONE file, core/<Name>Types.scala,
// holding an `object <Name>Types` with a nested `final case class` per active
// entity plus a request/match case class per active op.
//
// WHY A CONTAINER OBJECT: keeps the whole reference model in one file whatever
// the entity count and matches the java target's single-container layout
// (<Name>Types.java). Scala permits multiple top-level types per file, but a
// container object mirrors the JVM sibling and keeps the generated core/ dir
// tidy.
//
// TYPE CHOICE: reference `case class` types with BOXED (nullable) component
// types, NOT the wired runtime type. The generated ops take/return the loose
// object model (java.util.Map[String, Object] / Object), so these case classes
// are NOT wired into the op signatures — they are documentation/DX reference
// shapes a caller may use to describe a payload before converting it to a map.
// This mirrors the java target's reference records and the JS target's JSDoc
// typedefs (annotation only, no runtime effect). Emitting unused case classes
// is harmless — they compile and have no runtime effect.
//
// OPTIONAL FIELDS: every component is a boxed reference type, hence inherently
// nullable, so a `req:false` field/param needs no distinct rendering in Scala.
//
// Sentinels map to Scala types via the SHARED canonToType 'scala' column (the
// single source of truth per language — do not keep a local table here).
//
// Keep the SAME type-name scheme as every other language: <Name>,
// <Name>LoadMatch, <Name>ListMatch, <Name>CreateData, <Name>UpdateData,
// <Name>RemoveMatch (via the shared opTypeName helper).

import {
  cmp, each, names,
  File, Content,
} from '@voxgig/sdkgen'

import { canonToType, opTypeName, opRequestShape, warnEntityTypeCollisions , deriveEntityNames } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { scalaPackage } from './utility_scala'


const LANG = 'scala'


// Scala reserved words that cannot be a case-class parameter name.
const SCALA_KEYWORDS = new Set<string>([
  'abstract', 'case', 'catch', 'class', 'def', 'do', 'else', 'enum', 'export',
  'extends', 'false', 'final', 'finally', 'for', 'forSome', 'given', 'if',
  'implicit', 'import', 'lazy', 'match', 'new', 'null', 'object', 'override',
  'package', 'private', 'protected', 'return', 'sealed', 'super', 'then',
  'this', 'throw', 'trait', 'true', 'try', 'type', 'val', 'var', 'while',
  'with', 'yield',
])


// A field/param name that has a safe Scala identifier rendering. Names that are
// not valid identifiers (hyphens, leading digits) have no clean parameter form
// and are skipped — they remain reachable via the runtime map.
function scalaIdent(name: string): boolean {
  return /^[A-Za-z_][A-Za-z0-9_]*$/.test(name) && !SCALA_KEYWORDS.has(name)
}


// Emit a nested `final case class <typeName>(...)` from {name, type} items. An
// item whose name is not a legal identifier is skipped (WITH a warning — the
// key stays reachable via the runtime map, but its absence from the typed
// model should be visible, not silent); a duplicate component name (after the
// identifier filter) is dropped. An empty case class is a valid,
// zero-parameter shape.
function emitCaseClass(typeName: string, items: any[], log?: any): void {
  const seen = new Set<string>()
  const usable = items.filter((it: any) => {
    if (!it || null == it.name) {
      return false
    }
    if (!scalaIdent(it.name)) {
      if (log && log.warn) {
        log.warn({
          point: 'entity-types-skip-field', typeName, field: it.name,
          note: `scala: field "${it.name}" of ${typeName} has no legal ` +
            `Scala identifier form; omitted from the typed model (still ` +
            `reachable via the runtime map)`,
        })
      }
      return false
    }
    if (seen.has(it.name)) {
      return false
    }
    seen.add(it.name)
    return true
  })

  if (0 === usable.length) {
    Content(`  final case class ${typeName}()

`)
    return
  }

  const params = usable
    .map((it: any) => `${it.name}: ${canonToType(it.type, LANG)}`)
    .join(', ')
  Content(`  final case class ${typeName}(${params})

`)
}


const EntityTypes = cmp(function EntityTypes(props: any) {
  const { model, log } = props.ctx$
  const target = props.target || {}
  const ext = target.ext || 'scala'

  const scalapackage = props.scalapackage || scalaPackage(model)

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
  // `Name = undefined` below. Parity with the go/py/java/csharp emitter's fix.

  // Surface duplicate generated type names (two entities with the same
  // PascalCase Name) — they would redeclare a type in statically-typed
  // targets. Detection only; renaming is a model-level decision.
  warnEntityTypeCollisions(entity, log, LANG)

  File({ name: model.const.Name + 'Types.' + ext }, () => {

    Content(`package ${scalapackage}.core

// Typed reference models for the ${model.const.Name} SDK.
//
// GENERATED from the API model: main.${KIT}.entity.<e>.fields[] and per-op
// params (op.<name>.points[].args.params[]). Field/param types come from the
// canonical type sentinels (source of truth: @voxgig/apidef VALID_CANON). Do
// not edit by hand.
//
// These case classes are documentation/DX reference shapes ONLY. The SDK ops
// take and return the loose object model (java.util.Map[String, Object] /
// Object) at runtime, so these types are not wired into the op signatures —
// use them to describe a payload before converting it to a map. Every
// component is a boxed (nullable) type, so an optional (req:false) key needs
// no distinct rendering.

object ${model.const.Name}Types {

`)

    entityList.forEach((ent: any) => {
      const Name = ent.Name
      const fields = (ent.fields ? each(ent.fields) : [])
        .filter((f: any) => f.active !== false)

      // Entity data model: one component per field.
      emitCaseClass(Name, fields.map((f: any) => ({
        name: f.name, type: f.type,
      })), log)

      // Per active op: a request/match case class. Members come from the shared
      // partiality policy (opRequestShape).
      const ops = ent.op || {}
      ;['load', 'list', 'create', 'update', 'remove'].forEach((opname: string) => {
        if (null == ops[opname]) {
          return
        }

        const typeName = opTypeName(Name, opname)
        const { items } = opRequestShape(ent, opname)

        emitCaseClass(typeName, items, log)
      })
    })

    Content(`}
`)
  })
})


export {
  EntityTypes,
}
