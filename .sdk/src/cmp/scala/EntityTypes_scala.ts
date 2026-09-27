


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


function scalaIdent(name: string): boolean {
  return /^[A-Za-z_][A-Za-z0-9_]*$/.test(name) && !SCALA_KEYWORDS.has(name)
}


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

  warnEntityTypeCollisions(entity, log, LANG)

  File({ name: model.const.Name + 'Types.' + ext }, () => {

    Content(`package ${scalapackage}.core

// Typed reference models for the ${model.const.Name} SDK.
//
// GENERATED from the API model: main.${KIT}.entity.<e>.fields{} and per-op
// params (op.<name>.points[].g.params[]). Field/param types come from the
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
        .filter((f: any) => f.a !== false)

      emitCaseClass(Name, fields.map((f: any) => ({
        name: f.n, type: f.t,
      })), log)

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
