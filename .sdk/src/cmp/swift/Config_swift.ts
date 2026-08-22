
import {
  Content,
  File,
  cmp,
  configDefinition,
  each,
} from '@voxgig/sdkgen'


import {
  KIT,
  Model,
  getModelPath,
} from '@voxgig/apidef'


// Generates core/Config.swift: the SdkConfig enum holding the generated model
// config (makeConfig, materialised at runtime by parsing an embedded JSON
// literal - pure data, so a JSON round-trip is faithful and avoids emitting
// Value construction by hand) and the by-name feature factory (makeFeature).
// N-feature-safe: makeFeature emits a case per feature entry in the model.
const Config = cmp(async function Config(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model

  const feature = getModelPath(model, `main.${KIT}.feature`)

  // The config as data, built by the shared helper so every target embeds
  // the same model by construction. Passing target.name opts this target
  // into main.slug / main.version / main.target (the three station
  // descriptor identity fields, station design §4); swift has only the
  // JSON-literal rep, so that one call covers every rep this target emits.
  const { json } = configDefinition(model, target.name)

  // Model-data defaults may carry the ProjectName placeholder (e.g. the
  // clienttrack clientName); resolve it to the API name so the embedded JSON
  // matches the token-replaced runtime.
  const configJson = json.replace(/ProjectName/g, model.const.Name)

  File({ name: 'Config.' + target.ext }, () => {

    Content(`// ${model.const.Name} SDK - generated model configuration and feature
// factory. GENERATED from the API model - do not edit by hand.

import Foundation

public enum SdkConfig {
  public static func makeConfig() -> VMap {
    let json = #"""
${configJson}
"""#
    return (try? JSON.parse(json))?.asMap ?? VMap()
  }

  // SHARED CONFIG (sdkgen rung L2).
  //
  // The SDK reads the config on every request and never writes to it, so one
  // instance is shared by every client rather than rebuilt per client - the
  // difference between parsing the embedded JSON once and once per client.
  //
  // A static let in an enum is lazy and initialised exactly once, thread-safe
  // via swift_once.
  //
  // The result is SHARED: treat it as read-only. Callers that need to mutate
  // should use makeConfig, which always parses a fresh copy.
  private static let sharedConfigVal: VMap = makeConfig()

  public static func sharedConfig() -> VMap {
    return sharedConfigVal
  }

  public static func makeFeature(_ name: String) -> BaseFeature {
    switch name {
`)

    each(feature, (f: any) => {
      const fname = f.name.charAt(0).toUpperCase() + f.name.slice(1)
      if (f.name !== 'base') {
        Content(`    case "${f.name}": return ${fname}Feature()
`)
      }
    })

    Content(`    default: return BaseFeature()
    }
  }
}
`)
  })
})


export {
  Config
}
