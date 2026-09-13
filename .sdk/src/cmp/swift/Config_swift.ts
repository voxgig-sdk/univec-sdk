
import {
  Content,
  File,
  cmp,
  configDefinition,
  each,
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

  // Gated by the applicability tags, so this target never imports or
  // registers a feature it has no source for. One rule, one place:
  // helpers/applicability.
  const feature = targetFeatures(model, target)

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

  // PLUGIN DEFINITIONS AND THE featurePlugins MAP (the swift peer of
  // Config_go's featurePlugins / Config_ts's pluginDefs).
  //
  // Upstream sekreto replaced its self-registration registry with
  // voxgig/plugin definitions: a provider kind the caller did not pass in
  // via `plugins:` is unknown to that Sekreto. So the config names each
  // active plugin's exported Definition BY SYMBOL (the model's per-target
  // `def.swift` map - `hashicorp`, a top-level `let` in the vendored
  // SekretoPlugins module) and hands the list to the feature through
  // SdkConfig.featurePlugins.
  //
  // Typed `[String: [Any]]`, as go types it `[]any`, so Config never has to
  // name `Definition` - and so needs `import SekretoPlugins` only when a
  // definition is actually listed. The feature reads the list back and
  // downcasts.
  //
  // The ACCESSOR IS EMITTED UNCONDITIONALLY (empty map when nothing is
  // selected). Its caller, feature/SecretsFeature.swift, ships whenever the
  // feature is active, and java gated the accessor on "a feature declares a
  // plugin block" - which a project that never selected secrets does not
  // have - and shipped an SDK that did not compile (.handover-briefs/
  // fixb-java.md). One rule: what a template may reference, Config always
  // declares.
  const featurePlugins: Record<string, string[]> = {}
  each(feature, (f: any) => {
    const syms: string[] = []
    each(f.plugin, (plugin: any) => {
      // Filter on `active` HERE rather than trusting the feature object to
      // arrive filtered (see Config_ts.pluginImports: getting this wrong
      // names a definition the trim just deleted, and swiftc fails the
      // whole module on the unresolved symbol).
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
