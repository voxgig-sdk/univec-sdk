
import {
  Content,
  File,
  cmp,
  each,
  isAuthActive,
  isHttpBasicAuth,
  resolveAuthIn,
  resolveAuthName,
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
  const feature = targetFeatures(model, target)

  const headers = getModelPath(model, `main.${KIT}.config.headers`) || {}

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
  const authBasic = isHttpBasicAuth(model)
  // WHERE the credential goes and under what name, as apidef resolved them
  // from the spec's security scheme. Emitted below only when they DIFFER
  // from the defaults, so every header-based SDK's Config.scala stays
  // byte-identical.
  const authIn = resolveAuthIn(model)
  const authName = resolveAuthName(model)

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
    const auth: Record<string, any> = { prefix: authPrefix }
    if (authBasic) auth.basic = true
    if ('header' !== authIn) auth.in = authIn
    if ('Authorization' !== authName) auth.name = authName
    options.auth = auth
  }
  options.headers = headers
  options.entity = optionsEntity

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
