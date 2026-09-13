
import {
  Content,
  File,
  cmp,
  configDefinition,
  each,
  isAuthActive,
  resolveAuthPrefix,
  targetFeatures,
} from '@voxgig/sdkgen'


import {
  KIT,
  Model,
  getModelPath,
} from '@voxgig/apidef'


import {
  cleanModel,
  kotlinPackage,
  jsonAppendLines,
} from './utility_kotlin'


// Generates core/Config.kt: the static SDK configuration (makeConfig) and the
// by-name feature factory (makeFeature). The config itself is emitted as JSON
// chunks parsed at runtime by utility/Json.kt — chunked appends keep every
// string constant far below the JVM 64KB limit (N-feature/N-entity safe).
const Config = cmp(async function Config(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model
  const kotlinpackage = kotlinPackage(model)

  const entity = getModelPath(model, `main.${KIT}.entity`)
  // Gated by the applicability tags, so this target never imports or
  // registers a feature it has no source for. One rule, one place:
  // helpers/applicability.
  const feature = targetFeatures(model, target)

  const headers = getModelPath(model, `main.${KIT}.config.headers`) || {}

  const authActive = isAuthActive(model)
  const authPrefix = resolveAuthPrefix(model)

  let baseUrl = ''
  try { baseUrl = getModelPath(model, `main.${KIT}.info.servers.0.url`) } catch (_e) { }

  // Identity comes from configDefinition's def, not re-derived here, so
  // this target cannot disagree with the shared emitter on main.slug /
  // main.version / main.target (the three station descriptor fields,
  // station design §4) — passing target.name is what opts this target in.
  const { def: configDef } = configDefinition(model, target.name)

  // The feature block comes from configDefinition's def, not from
  // f.config, so it carries each feature's `transport` role (station
  // design §8.4) beside its options and cannot drift from the shared
  // emitter.
  const featureConfig: Record<string, any> = {}
  each(feature, (f: any) => {
    featureConfig[f.name] = cleanModel(configDef.feature[f.name] || {})
  })

  const optionsEntity: Record<string, any> = {}
  each(entity, (ent: any) => {
    optionsEntity[ent.name] = {}
  })

  const options: Record<string, any> = {
    base: baseUrl,
  }
  if (authActive) {
    options.auth = { prefix: authPrefix }
  }
  options.headers = headers
  options.entity = optionsEntity

  // configDefinition's `def.entity` verbatim, NOT rebuilt here. This reduce
  // was one of fourteen copies of that function's entityDefs loop, and when
  // configDefinition started reconstructing a point's `parts` from apidef's
  // segment vector (its ADR-003), only the copies that read `configDef` got
  // it — this target's literal config emitted paths with no parts at all
  // while its data config had them. One rule, one place.
  const entityConfig = configDef.entity

  // THE PLUGIN DEFINITIONS the model selected, per feature.
  //
  // sekreto's contract since the registry was retired: a kind not passed
  // in `plugins` is unknown to that Sekreto, so the model's choice of
  // plugin groups IS the SDK's provider vocabulary. This walks the
  // catalogue's active `plugin.def.kotlin` entries and hands the list to
  // the feature through `Config.featurePlugins`.
  //
  // Kotlin's Definition symbols are PLAIN TOP-LEVEL VALS
  // (`val hashicorp: Definition = providerplugin("hashicorp") {...}`), so
  // the def key is the val name and the import is that name qualified by
  // the file's package - DERIVED from the def path (`feature/secrets/
  // sekreto/plugins/Hashicorp.kt` -> `feature.secrets.sekreto.plugins`)
  // rather than hardcoding `secrets`, exactly as the go emitter does.
  //
  // Emitted in core, which already names KOTLINPACKAGE.feature classes in
  // makeFeature - Kotlin has no package-cycle rule, so nothing here can
  // introduce one. The feature reads it back as List<Any?> and filters by
  // type, so a tree with the feature present but no group selected still
  // compiles with no import at all.
  const pluginImports = new Set<string>()
  const featurePlugins: Record<string, string[]> = {}

  each(feature, (f: any) => {
    const syms: string[] = []
    each(f.plugin, (plugin: any) => {
      // Filter on `active` HERE rather than trusting the feature object to
      // arrive filtered: getting this wrong emits an import for a file the
      // plugin trim just deleted, and the SDK does not compile.
      if (false === plugin.active || null == plugin.active) return
      for (const [sym, one] of Object.entries(plugin.def?.kotlin || {})) {
        const dir = String(one).replace(/\/[^/]+$/, '').replace(/\//g, '.')
        // A dotted symbol (another language's class-qualified spelling)
        // imports its HEAD; kotlin's own keys are bare val names.
        pluginImports.add(
          kotlinpackage + '.' + dir + '.' + String(sym).split('.')[0])
        syms.push(sym)
      }
    })
    if (0 < syms.length) {
      featurePlugins[f.name] = syms.sort()
    }
  })

  const pluginImportBlock = Array.from(pluginImports).sort()
    .map((one: string) => 'import ' + one + '\n').join('')

  const featurePluginsBlock =
    Object.keys(featurePlugins).sort().map((fname: string) =>
      '    "' + fname + '" to listOf(' +
      featurePlugins[fname].join(', ') + '),\n').join('')

  const config = {
    main: configDef.main,
    feature: featureConfig,
    options,
    entity: entityConfig,
  }

  File({ name: 'Config.' + target.ext }, () => {

    Content(`package ${kotlinpackage}.core

import ${kotlinpackage}.utility.Json
${pluginImportBlock}
/** Static SDK configuration and by-name feature construction. */
@Suppress("UNCHECKED_CAST")
object Config {

  fun makeConfig(): MutableMap<String, Any?> {
    return Json.parse(configJson()) as MutableMap<String, Any?>
  }

  // SHARED CONFIG (sdkgen rung L2).
  //
  // The SDK reads the config on every request and never writes to it, so one
  // instance is shared by every client rather than rebuilt per client - the
  // difference between parsing the embedded JSON once and once per client.
  //
  // 'by lazy' defaults to LazyThreadSafetyMode.SYNCHRONIZED, so concurrent
  // first calls build it exactly once.
  //
  // The returned map is SHARED: treat it as read-only. Callers that need to
  // mutate should use makeConfig, which always parses a fresh copy.
  private val sharedConfigVal: MutableMap<String, Any?> by lazy { makeConfig() }

  fun sharedConfig(): MutableMap<String, Any?> = sharedConfigVal

  fun makeFeature(name: String): Feature {
    return when (name) {
`)

    each(feature, (f: any) => {
      const fname = f.name.charAt(0).toUpperCase() + f.name.slice(1)
      if (f.name !== 'base') {
        Content(`      "${f.name}" -> ${kotlinpackage}.feature.${fname}Feature()
`)
      }
    })

    Content(`      else -> ${kotlinpackage}.feature.BaseFeature()
    }
  }

  // The plugin definitions the model selected per feature, as List<Any?>
  // so core need not name a feature's types. Empty when no active feature
  // declares active plugin groups for this target - and then no plugin
  // import is emitted either.
  private val featurePluginsMap: Map<String, List<Any?>> = mapOf(
${featurePluginsBlock}  )

  // featurePlugins is the definitions list for one feature's chain.
  fun featurePlugins(name: String): List<Any?> = featurePluginsMap[name] ?: emptyList()

  private fun configJson(): String {
    val b = StringBuilder()
`)

    Content(jsonAppendLines(config, 'b'))

    Content(`    return b.toString()
  }
}
`)
  })
})


export {
  Config
}
