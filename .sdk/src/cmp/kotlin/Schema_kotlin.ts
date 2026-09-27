import {
  Content,
  File,
  cmp,
  entitySpecMap,
  optionSpec,
} from '@voxgig/sdkgen'


import {
  Model,
} from '@voxgig/apidef'


import {
  kotlinPackage,
  jsonAppendLines,
} from './utility_kotlin'


const Schema = cmp(async function Schema(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model
  const kotlinpackage = kotlinPackage(model)

  const optspec = optionSpec(model, target.name)
  const entityspec = entitySpecMap(model, target.name) || {}

  // Beside Config.kt, and for the same reason: core owns the generated data,
  // so nothing in utility or feature has to reach up for it.
  File({ name: 'Schema.' + target.ext }, () => {

    Content(`package ${kotlinpackage}.core

import ${kotlinpackage}.utility.Json

/**
 * ${model.const.Name} ${target.Name} SDK: generated schemas. Do not edit.
 *
 * Generated from the model: \`main.kit.optspec\` and each feature's
 * \`config.options\` for the option spec; entity \`fields{}.type\` for the
 * entity specs.
 */
@Suppress("UNCHECKED_CAST")
object Schema {

  // Parsed ONCE, on first use. The spec is read on every client construction
  // and never mutated, so a per-call parse would be pure waste — and a shared
  // map is safe for the same reason the spec is a constant: makeOptions
  // validates AGAINST it and writes into the options, never into the spec.
  //
  // 'by lazy' defaults to LazyThreadSafetyMode.SYNCHRONIZED, as
  // Config.sharedConfig uses, so concurrent first calls parse it exactly once.

  /** The option spec makeOptions validates client options against. */
  val optspec: MutableMap<String, Any?> by lazy {
    Json.parse(optspecJson()) as MutableMap<String, Any?>
  }

  /** Per-entity data and request specs, keyed by entity name. */
  val entityspec: MutableMap<String, Any?> by lazy {
    Json.parse(entityspecJson()) as MutableMap<String, Any?>
  }

  private fun optspecJson(): String {
    val b = StringBuilder()
`)

    Content(jsonAppendLines(optspec, 'b'))

    Content(`    return b.toString()
  }

  private fun entityspecJson(): String {
    val b = StringBuilder()
`)

    Content(jsonAppendLines(entityspec, 'b'))

    Content(`    return b.toString()
  }
}
`)
  })
})


export {
  Schema
}
