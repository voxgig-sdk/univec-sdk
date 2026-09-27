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


const Schema = cmp(async function Schema(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model

  const optspec = optionSpec(model, target.name)
  const entityspec = entitySpecMap(model, target.name) || {}

  const optspecJson = JSON.stringify(optspec, null, 2)
  const entityspecJson = JSON.stringify(entityspec, null, 2)

  // Beside Config.swift, and for the same reason: core owns the generated
  // data, so nothing in the copied runtime has to reach up for it.
  File({ name: 'Schema.' + target.ext }, () => {

    Content(`// ${model.const.Name} SDK - generated schemas. GENERATED from the API model -
// do not edit by hand.
//
// Built from the model: \`main.kit.optspec\` and each feature's
// \`config.options\` for optspec; entity \`fields{}.type\` for entityspec.

import Foundation

public enum SdkSchema {

  // Parsed ONCE, on first use. The spec is read on every client construction
  // and never mutated, so a per-call parse would be pure waste - and a shared
  // VMap is safe for the same reason the spec is a constant: makeOptions
  // validates AGAINST it and writes into the options, never into the spec.
  //
  // A static let in an enum is lazy and initialised exactly once, thread-safe
  // via swift_once, as SdkConfig.sharedConfigVal is.
  //
  // The results are SHARED: treat them as read-only.

  /// The option spec makeOptions validates client options against.
  public static let optspec: Value = {
    let json = #"""
${optspecJson}
"""#
    return (try? JSON.parse(json)) ?? .map(VMap())
  }()

  /// Per-entity data and request specs, keyed by entity name.
  public static let entityspec: Value = {
    let json = #"""
${entityspecJson}
"""#
    return (try? JSON.parse(json)) ?? .map(VMap())
  }()
}
`)
  })
})


export {
  Schema
}
