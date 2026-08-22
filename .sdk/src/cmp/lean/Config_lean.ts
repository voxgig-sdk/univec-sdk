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
  clean,
  leanString,
} from './utility_lean'


// SdkConfig.lean: the embedded API model, serialised to a JSON string. The
// config-driven runtime (SdkRuntime) parses it into a struct `Value` at client
// construction — the whole SDK is data-driven, so there is no per-entity code.
const Config = cmp(async function Config(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model

  const entity = getModelPath(model, `main.${KIT}.entity`)
  const feature = getModelPath(model, `main.${KIT}.feature`)
  const headers = getModelPath(model, `main.${KIT}.config.headers`) || {}

  const authActive = isAuthActive(model)
  const authPrefix = resolveAuthPrefix(model)

  let baseUrl = ''
  try { baseUrl = getModelPath(model, `main.${KIT}.info.servers.0.url`) } catch (_e) { }

  const featureConfig: any = {}
  each(feature, (f: any) => { featureConfig[f.name] = f.config || {} })

  const entityOptions: any = {}
  each(entity, (ent: any) => { entityOptions[ent.name] = {} })

  const options: any = {
    base: baseUrl,
    headers,
    entity: entityOptions,
  }
  if (authActive) {
    options.auth = { prefix: authPrefix }
  }

  const entityConfig = Object.values(entity || {}).reduce((a: any, n: any) => (
    a[n.name] = clean({
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

  File({ name: 'SdkConfig.' + target.ext }, () => {
    Content(`-- Generated API configuration for the config-driven runtime.
-- The embedded model is parsed into a struct Value at client construction.

namespace SdkConfig

def configJson : String :=
  ${leanString(JSON.stringify(config))}

end SdkConfig
`)
  })
})


export {
  Config
}
