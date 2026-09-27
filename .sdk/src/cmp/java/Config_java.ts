
import {
  Content,
  File,
  cmp,
  configDefinition,
  each,
  isAuthActive,
  isHttpBasicAuth,
  resolveAuthIn,
  resolveAuthName,
  resolveAuthPrefix,
  targetFeatures,
} from '@voxgig/sdkgen'


import {
  serverVariables,
} from '@voxgig/sdkgen'


import {
  KIT,
  Model,
  getModelPath,
} from '@voxgig/apidef'


import {
  cleanModel,
  javaPackage,
  jsonAppendLines,
} from './utility_java'


// Generates core/Config.java: the static SDK configuration (makeConfig)
// and the by-name feature factory (makeFeature). The config itself is
// emitted as JSON chunks parsed at runtime by utility/Json.java — chunked
// appends keep every string constant far below the JVM 64KB limit no
// matter how large the API model grows (N-feature/N-entity safe).
const Config = cmp(async function Config(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model
  const javapackage = javaPackage(model)

  const entity = getModelPath(model, `main.${KIT}.entity`)
  const feature = targetFeatures(model, target)

  const headers = getModelPath(model, `main.${KIT}.config.headers`) || {}

  const authActive = isAuthActive(model)
  const authPrefix = resolveAuthPrefix(model)
  const authBasic = isHttpBasicAuth(model)
  const authIn = resolveAuthIn(model)
  const authName = resolveAuthName(model)

  let baseUrl = ''
  try { baseUrl = getModelPath(model, `main.${KIT}.info.servers.0.url`) } catch (_e) { }

  const { def: configDef } = configDefinition(model, target.name)

  const pluginImports = new Set<string>()
  const featurePlugins: Record<string, string[]> = {}

  each(feature, (f: any) => {
    const syms: string[] = []
    each(f.plugin, (plugin: any) => {
      if (false === plugin.active || null == plugin.active) return
      for (const [sym, one] of Object.entries(plugin.def?.java || {})) {
        const dir = String(one).replace(/\/[^/]+$/, '').replace(/\//g, '.')
        pluginImports.add(javapackage + '.' + dir + '.' + sym.split('.')[0])
        syms.push(sym)
      }
    })

    if (0 < syms.length) {
      featurePlugins[f.name] = Array.from(new Set(syms)).sort()
    }
  })

  const pluginImportBlock = Array.from(pluginImports).sort()
    .map((p: string) => `import ${p};\n`).join('')

  const featurePluginsBlock =
    `  /**
   * The plugin definitions the model selected for one feature's chain, as
   * List&lt;Object&gt; so core never names a vendored type. Empty for a
   * feature whose model declares no active plugin group.
   */
  public static List<Object> featurePlugins(String name) {
    switch (name) {
` +
    Object.keys(featurePlugins).sort().map((fname: string) =>
      `      case "${fname}":
        return List.of(${featurePlugins[fname].join(', ')});
`).join('') +
    `      default:
        return List.of();
    }
  }

`

  // Assemble the config shape (mirrors Config_go's emitted map). The
  // feature block comes from configDefinition's def, not from f.config,
  // so it carries each feature's `transport` role (station design §8.4)
  // beside its options and cannot drift from the shared emitter.
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

  // Templated server URL: emit the spec's server-variable defaults so the
  // runtime can substitute {name} placeholders in base (see MakeOptions).
  // Without this block the placeholder reaches the wire verbatim — java
  // shipped `http://host/api/{account_id}/element` as a real URL, which is
  // worse than the construction error every other target raises.
  const svars = serverVariables(model)
  if (0 < svars.length) {
    options.server = svars.reduce(
      (a: any, v: any) => (a[v.name] = v.dflt, a), {} as Record<string, string>)
  }

  if (authActive) {
    const auth: Record<string, any> = { prefix: authPrefix }
    if (authBasic) { auth.basic = true }
    if ('header' !== authIn) { auth.in = authIn }
    if ('Authorization' !== authName) { auth.name = authName }
    options.auth = auth
  }
  options.headers = headers
  options.entity = optionsEntity

  const entityConfig = configDef.entity

  const config = {
    main: configDef.main,
    feature: featureConfig,
    options,
    entity: entityConfig,
  }

  File({ name: 'Config.' + target.ext }, () => {

    Content(`package ${javapackage}.core;

import java.util.List;
import java.util.Map;

import ${javapackage}.utility.Json;
${pluginImportBlock}
/** Static SDK configuration and by-name feature construction. */
@SuppressWarnings({"unchecked"})
public final class Config {

  private Config() {}

  public static Map<String, Object> makeConfig() {
    return (Map<String, Object>) Json.parse(configJson());
  }

  // SHARED CONFIG (sdkgen rung L2).
  //
  // The SDK reads the config on every request and never writes to it, so one
  // instance is shared by every client rather than rebuilt per client - the
  // difference between parsing the embedded JSON once and once per client.
  //
  // Initialization-on-demand holder: the JLS guarantees the class initializer
  // runs once, lazily, and safely under concurrency, with no locking on the
  // read path.
  private static final class SharedHolder {
    static final Map<String, Object> VALUE = makeConfig();
  }

  // The process-wide config, built once on first use.
  //
  // The returned map is SHARED: treat it as read-only. Callers that need to
  // mutate should use makeConfig, which always parses a fresh copy.
  public static Map<String, Object> sharedConfig() {
    return SharedHolder.VALUE;
  }

  public static Feature makeFeature(String name) {
    switch (name) {
`)

    each(feature, (f: any) => {
      const fname = f.name.charAt(0).toUpperCase() + f.name.slice(1)
      if (f.name !== 'base') {
        Content(`      case "${f.name}":
        return new ${javapackage}.feature.${fname}Feature();
`)
      }
    })

    Content(`      default:
        return new ${javapackage}.feature.BaseFeature();
    }
  }

${featurePluginsBlock}  private static String configJson() {
    StringBuilder b = new StringBuilder();
`)

    Content(jsonAppendLines(config, 'b'))

    Content(`    return b.toString();
  }
}
`)
  })
})


export {
  Config
}
