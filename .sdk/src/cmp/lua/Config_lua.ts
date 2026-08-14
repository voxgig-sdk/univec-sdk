
import * as Path from 'node:path'


import {
  Content,
  File,
  Fragment,
  Line,
  cmp,
  each,
  isAuthActive,
  resolveAuthPrefix,
  serverVariables,
} from '@voxgig/sdkgen'


import {
  KIT,
  Model,
  getModelPath,
  nom,
} from '@voxgig/apidef'


import {
  clean,
  formatLuaTable,
} from './utility_lua'


const Config = cmp(async function Config(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model

  const entity = getModelPath(model, `main.${KIT}.entity`)
  const feature = getModelPath(model, `main.${KIT}.feature`)

  const headers = getModelPath(model, `main.${KIT}.config.headers`) || {}

  const authActive = isAuthActive(model)
  // config.auth.prefix override -> spec-derived info.security.prefix -> 'Bearer'
  const authPrefix = resolveAuthPrefix(model)

  let baseUrl = ''
  try { baseUrl = getModelPath(model, `main.${KIT}.info.servers.0.url`) } catch (_e) { }

  // Templated server URL: emit the spec's server-variable defaults so the
  // runtime can substitute {name} placeholders in base (see make_options).
  const svars = serverVariables(model)
  const serverBlock = 0 === svars.length ? '' :
    '      server = {\n' +
    svars.map((v: any) => `        [${JSON.stringify(v.name)}] = ${JSON.stringify(v.dflt)},\n`).join('') +
    '      },\n'

  const authBlock = authActive
    ? `      auth = {
        prefix = "${authPrefix}",
      },\n`
    : ''

  File({ name: 'config.' + target.ext }, () => {

    Content(`-- ${model.const.Name} SDK configuration

-- Build a fresh, fully materialised config table. Every call rebuilds the
-- whole structure, so prefer require("config_shared") unless you need a
-- private copy you intend to mutate.
local function make_config()
  return {
    main = {
      name = "${model.const.Name}",
    },
    feature = {
`)

    each(feature, (f: any) => {
      const fconfig = f.config || {}
      Content(`      ["${f.name}"] = ${formatLuaTable(fconfig, 3)},
`)
    })

    Content(`    },
    options = {
      base = "${baseUrl}",
${serverBlock}${authBlock}      headers = ${formatLuaTable(headers, 3)},
      entity = {
`)

    each(entity, (entity: any) => {
      Content(`        ["${entity.name}"] = {},
`)
    })

    Content(`      },
    },
    entity = ${formatLuaTable(
      Object.values(entity).reduce((a: any, n: any) => (a[n.name] = clean({
        fields: n.fields,
        name: n.name,
        op: n.op,
        relations: n.relations,
      }, true), a), {}), 2)},
  }
end


local function make_feature(name)
  local features = require("features")
  local factory = features[name]
  if factory ~= nil then
    return factory()
  end
  return features.base()
end


-- Attach make_feature to the SDK class
local function setup_sdk(SDK)
  SDK._make_feature = make_feature
end


return make_config
`)
  })

  // A sibling module rather than a member of `config`: `config` returns a
  // bare function (`require("config")()`), and turning it into a table would
  // change its observable type for any consumer holding it as a factory.
  File({ name: 'config_shared.' + target.ext }, () => {
    Content(`-- ${model.const.Name} SDK shared configuration

local make_config = require("config")

local value = nil


-- Return the config for this Lua state, built once on first use. The SDK
-- reads the config on every request and never writes to it, so one instance
-- is shared by every client rather than rebuilt per client.
--
-- The returned table is shared: treat it as read-only. Callers that need to
-- mutate should use require("config")(), which always returns a fresh copy.
return function()
  if value == nil then
    value = make_config()
  end
  return value
end
`)
  })
})


export {
  Config
}
