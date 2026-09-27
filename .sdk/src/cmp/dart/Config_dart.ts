
import * as Path from 'node:path'


import {
  File,
  Fragment,
  Line,
  cmp,
  configDefinition,
  configReprSetting,
  each,
  isConfigData,
  isAuthActive,
  resolveAuthPrefix,
  targetFeatures,
} from '@voxgig/sdkgen'


import {
  KIT,
  Model,
  getModelPath,
  nom,
} from '@voxgig/apidef'


import {
  dartStringLiteral,
  dartValue,
} from './utility_dart'


const Config = cmp(async function Config(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model

  const entity = getModelPath(model, `main.${KIT}.entity`)
  const feature = targetFeatures(model, target)

  const ff = Path.normalize(__dirname + '/../../../src/cmp/dart/fragment/')

  const headers = getModelPath(model, `main.${KIT}.config.headers`) || {}

  const authActive = isAuthActive(model)
  const authPrefix = resolveAuthPrefix(model)
  const authBlock = authActive
    ? `'auth': <String, dynamic>{
      'prefix': '${authPrefix}',
    },

    `
    : ''

  let baseUrl = ''
  try {
    baseUrl = getModelPath(model, `main.${KIT}.info.servers.0.url`)
  } catch (_e) { }

  const { def: configDef, json: configJson } = configDefinition(model, target.name)
  const asData = isConfigData(configJson, configReprSetting(model))

  File({ name: 'Config.' + target.ext }, () => {

    if (asData) {
      Fragment({
        from: ff + 'Config.data.fragment.dart',

        replace: {
          ...ctx$.stdrep,

          '// #ImportFeatures': () => each(feature, (f: any) => {
            Line(`import 'feature/${f.name}/${nom(f, 'Name')}Feature.dart';`)
          }),

          '// #FeatureClasses': () => each(feature, (f: any) => {
            Line(`  '${f.name}': () => ${nom(f, 'Name')}Feature(),`)
          }),

          '// #ImportPlugins': () => pluginImports(feature),

          '// #FeaturePlugins': () => pluginDefs(feature),

          "'CONFIGJSON'": dartStringLiteral(configJson),
        }
      })
      return
    }

    Fragment({
      from: ff + 'Config.fragment.dart',

      replace: {

        // Config.fragment.dart carries `'name': 'ProjectName'` — without the
        // standard replacements the generated SDK reports "ProjectName" as its
        // own name at runtime. Every sibling dart component already spreads
        // these; this one did not.
        ...ctx$.stdrep,

        // Identity beyond the camel Name: slug/version/target (station
        // descriptor inputs). Values from configDefinition's def, not
        // re-derived here, so the literal rep and the data rep cannot
        // disagree (the Config_ts #MainMeta discipline).
        '// #MainMeta': () => {
          Line(`    'slug': ${dartValue(configDef.main.slug)},`)
          Line(`    'version': ${dartValue(configDef.main.version)},`)
          Line(`    'target': ${dartValue(configDef.main.target)},`)
        },

        "'OPTIONSMAP'": dartValue(configDef.options, 1),

        '// #ImportFeatures': () => each(feature, (f: any) => {
          Line(`import 'feature/${f.name}/${nom(f, 'Name')}Feature.dart';`)
        }),

        '// #FeatureClasses': () => each(feature, (f: any) => {
          Line(`  '${f.name}': () => ${nom(f, 'Name')}Feature(),`)
        }),

        '// #ImportPlugins': () => pluginImports(feature),

        '// #FeaturePlugins': () => pluginDefs(feature),

        // Rendered from configDefinition's def, not from f.config, so the
        // literal carries the feature's `transport` role (station design
        // §8.4) beside its options and cannot drift from the data rep.
        '// #FeatureConfigs': () => each(feature, (f: any) => {
          Line(`    '${f.name}': ${dartValue(configDef.feature[f.name], 2)},`)
        }),


        '// #EntityConfigs': () => each(entity, (entity: any) => {
          Line(`      '${entity.name}': <String, dynamic>{},`)
        }),

        "'ENTITYMAP'": dartValue(configDef.entity, 1),
      }
    })
  })
})


function pluginImports(feature: any) {
  each(feature, (f: any) => {
    const bypath: Record<string, string[]> = {}

    each(f.plugin, (plugin: any) => {
      if (false === plugin.active || null == plugin.active) return

      for (const [sym, one] of Object.entries(plugin.def?.dart || {})) {
        const path = String(one)
          ; (bypath[path] = bypath[path] || []).push(sym)
      }
    })

    for (const path of Object.keys(bypath).sort()) {
      const spec = path.replace(/^lib\//, '')
      const syms = Array.from(new Set(bypath[path])).sort()
      Line(`import '${spec}' show ${syms.join(', ')};`)
    }
  })
}


function pluginDefs(feature: any) {
  each(feature, (f: any) => {
    const syms: string[] = []
    each(f.plugin, (plugin: any) => {
      if (false === plugin.active || null == plugin.active) return
      syms.push(...Object.keys(plugin.def?.dart || {}))
    })
    if (0 < syms.length) {
      Line(`  '${f.name}': [${Array.from(new Set(syms)).sort().join(', ')}],`)
    }
  })
}


export {
  Config
}
