
import {
  Content,
  File,
  cmp,
  configDefinition,
  each,
  resolveAuthIn,
  resolveAuthName,
  targetFeatures,
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

  const feature = targetFeatures(model, target)

  const { def } = configDefinition(model, target.name)

  const authIn = resolveAuthIn(model)
  const authName = resolveAuthName(model)
  const authOpt: any = (def as any)?.options?.auth
  if (null != authOpt) {
    if ('header' !== authIn) authOpt.in = authIn
    if ('Authorization' !== authName) authOpt.name = authName
  }

  const json = JSON.stringify(def)

  const configJson = json.replace(/ProjectName/g, model.const.Name)

  const featurePlugins: Record<string, string[]> = {}
  each(feature, (f: any) => {
    const syms: string[] = []
    each(f.plugin, (plugin: any) => {
      if (false === plugin.active || null == plugin.active) return
      for (const sym of Object.keys(plugin.def?.swift || {})) {
        syms.push(sym)
      }
    })
    if (0 < syms.length) {
      featurePlugins[f.name] = syms.sort()
    }
  })

  const pluginImport = 0 === Object.keys(featurePlugins).length ? '' :
    '\nimport SekretoPlugins\n'

  const featurePluginsBlock = 0 === Object.keys(featurePlugins).length ?
    '  private static let featurePluginsVal: [String: [Any]] = [:]\n' :
    '  private static let featurePluginsVal: [String: [Any]] = [\n' +
    Object.keys(featurePlugins).sort().map((fname: string) =>
      `    "${fname}": [${featurePlugins[fname].join(', ')}],\n`).join('') +
    '  ]\n'

  File({ name: 'Config.' + target.ext }, () => {

    Content(`// ${model.const.Name} SDK - generated model configuration and feature
// factory. GENERATED from the API model - do not edit by hand.

import Foundation
${pluginImport}
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

  // The plugin definitions the model selected per feature, as [Any] so a
  // feature can consume them without core naming the plugin module's
  // types. Empty when no active feature declares active plugin groups for
  // this target.
${featurePluginsBlock}
  // featurePlugins is the definitions list for one feature's chain.
  public static func featurePlugins(_ name: String) -> [Any] {
    return featurePluginsVal[name] ?? []
  }
}
`)
  })
})


export {
  Config
}
