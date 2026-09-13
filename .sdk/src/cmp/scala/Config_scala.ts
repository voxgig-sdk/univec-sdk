
import {
  Content,
  File,
  cmp,
  each,
  isAuthActive,
  resolveAuthPrefix,
  targetFeatures,
  configDefinition,
} from '@voxgig/sdkgen'


import {
  KIT,
  Model,
  getModelPath,
} from '@voxgig/apidef'


import {
  cleanModel,
  scalaPackage,
  jsonAppendLines,
} from './utility_scala'


// Generates core/Config.scala: the static SDK configuration (makeConfig) and
// the by-name feature factory (makeFeature). The config itself is emitted as
// JSON chunks parsed at runtime by utility/Json.java — chunked appends keep
// every string constant far below the JVM 64KB limit (N-feature/N-entity safe).
const Config = cmp(async function Config(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model
  const scalapackage = scalaPackage(model)

  const entity = getModelPath(model, `main.${KIT}.entity`)
  const { def: configDef } = configDefinition(model, target.name)
  // Gated by the applicability tags, so this target never imports or
  // registers a feature it has no source for. One rule, one place:
  // helpers/applicability.
  const feature = targetFeatures(model, target)

  const headers = getModelPath(model, `main.${KIT}.config.headers`) || {}

  // PLUGIN DEFINITIONS, per feature (the scala peer of Config_go's
  // featurePlugins map and Config_ts's pluginDefs).
  //
  // Since sekreto retired its import-time registry, provider kinds are
  // voxgig/plugin definitions: a kind the caller did not pass in via
  // `plugins` is unknown to that Sekreto. So the config names each active
  // plugin's exported Definition and hands the list to the feature.
  //
  // The scala symbols are fully-qualified top-level `val`s
  // (`com.voxgig.sekreto.plugins.hashicorp`), so unlike go there is no
  // import to emit - and an inactive group therefore leaves no reference at
  // all behind for the generate-time plugin trim to dangle.
  //
  // Typed List[Any], never List[Definition]: core must not name a vendored
  // type, or a tree carrying the feature source without the feature selected
  // would fail to compile.
  const featurePlugins: Record<string, string[]> = {}
  each(feature, (f: any) => {
    const syms: string[] = []
    each(f.plugin, (plugin: any) => {
      // Filter on `active` HERE rather than trusting the feature object to
      // arrive filtered (the trap Config_ts documents): naming a symbol the
      // trim just deleted is a build break, not a warning.
      if (false === plugin.active || null == plugin.active) return
      for (const sym of Object.keys(plugin.def?.scala || {})) {
        syms.push(sym)
      }
    })
    if (0 < syms.length) {
      featurePlugins[f.name] = syms.sort()
    }
  })

  const featurePluginsBlock =
    Object.keys(featurePlugins).sort().map((fname: string) =>
      `    case "${fname}" => List(${featurePlugins[fname].join(', ')})\n`).join('')

  const authActive = isAuthActive(model)
  const authPrefix = resolveAuthPrefix(model)

  let baseUrl = ''
  try { baseUrl = getModelPath(model, `main.${KIT}.info.servers.0.url`) } catch (_e) { }

  const featureConfig: Record<string, any> = {}
  each(feature, (f: any) => {
    featureConfig[f.name] = cleanModel(f.config || {})
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

  const config = {
    main: { name: model.const.Name },
    feature: featureConfig,
    options,
    entity: entityConfig,
  }

  File({ name: 'Config.' + target.ext }, () => {

    Content(`package ${scalapackage}.core

import java.util.{Map => JMap}

import ${scalapackage}.utility.Json

// Static SDK configuration and by-name feature construction.
object Config {

  def makeConfig(): JMap[String, Object] =
    Json.parse(configJson()).asInstanceOf[JMap[String, Object]]

  // SHARED CONFIG (sdkgen rung L2).
  //
  // The SDK reads the config on every request and never writes to it, so one
  // instance is shared by every client rather than rebuilt per client - the
  // difference between parsing the embedded JSON once and once per client.
  //
  // A lazy val is initialised once, on first use, under a lock, so
  // concurrent first calls build it exactly once.
  //
  // The returned map is SHARED: treat it as read-only. Callers that need to
  // mutate should use makeConfig, which always parses a fresh copy.
  private lazy val sharedConfigVal: JMap[String, Object] = makeConfig()

  def sharedConfig(): JMap[String, Object] = sharedConfigVal

  // The plugin definitions the model selected per feature, as List[Any] so a
  // feature consumes them without core naming a vendored type. Empty when no
  // active feature declares active plugin groups for this target.
  def featurePlugins(name: String): List[Any] = name match {
${featurePluginsBlock}    case _ => Nil
  }

  def makeFeature(name: String): Feature = name match {
`)

    each(feature, (f: any) => {
      const fname = f.name.charAt(0).toUpperCase() + f.name.slice(1)
      if (f.name !== 'base') {
        Content(`    case "${f.name}" => new ${scalapackage}.feature.${fname}Feature()
`)
      }
    })

    Content(`    case _ => new ${scalapackage}.feature.BaseFeature()
  }

  private def configJson(): String = {
    val b = new StringBuilder()
`)

    Content(jsonAppendLines(config, 'b'))

    Content(`    b.toString
  }
}
`)
  })
})


export {
  Config
}
