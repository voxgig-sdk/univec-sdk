
import {
  Content,
  File,
  cmp,
  each,
  isAuthActive,
  resolveAuthPrefix,
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
  const feature = getModelPath(model, `main.${KIT}.feature`)

  const headers = getModelPath(model, `main.${KIT}.config.headers`) || {}

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

  const entityConfig = Object.values(entity).reduce((a: any, n: any) => (
    a[n.name] = cleanModel({
      fields: n.fields,
      name: n.name,
      op: n.op,
      relations: n.relations,
    }, true), a), {})

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
