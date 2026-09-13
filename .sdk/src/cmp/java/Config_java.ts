
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
  // Gated by the applicability tags, so this target never imports or
  // registers a feature it has no source for. One rule, one place:
  // helpers/applicability.
  const feature = targetFeatures(model, target)

  const headers = getModelPath(model, `main.${KIT}.config.headers`) || {}

  const authActive = isAuthActive(model)
  // config.auth.prefix override -> spec-derived info.security.prefix -> 'Bearer'
  const authPrefix = resolveAuthPrefix(model)

  let baseUrl = ''
  try { baseUrl = getModelPath(model, `main.${KIT}.info.servers.0.url`) } catch (_e) { }

  // Identity comes from configDefinition's def, not re-derived here, so
  // this target cannot disagree with the shared emitter on main.slug /
  // main.version / main.target (the three station descriptor fields,
  // station design §4) — passing target.name is what opts this target in.
  const { def: configDef } = configDefinition(model, target.name)

  // PLUGIN DEFINITIONS, per feature — the java peer of Config_go's
  // featurePlugins map (and of Config_ts's pluginImports/pluginDefs).
  //
  // Upstream sekreto replaced its self-registration registry with
  // voxgig/plugin definitions: a provider kind the caller did not pass in
  // via `plugins(...)` is unknown to that Sekreto. So the config imports
  // each active plugin's exported Definition BY NAME (the model's
  // per-target `def` map — `Hashicorp.PLUGIN`, a class-qualified java
  // symbol) and hands the list to the feature through
  // Config.featurePlugins.
  //
  // Emitted in core (not in the feature package) so the dependency runs
  // core -> plugins -> sekreto -> plugin with no cycle; the feature reads
  // it back as List<Object> and instanceof-tests, so core never names a
  // vendored type.
  const pluginImports = new Set<string>()
  const featurePlugins: Record<string, string[]> = {}

  // featurePlugins is emitted UNCONDITIONALLY — the method always exists,
  // and answers List.of() for a name with no active groups. This is the go
  // donor's shape (Config_go emits `var featurePlugins = map[string][]any`
  // with no gate) and it is not a stylistic choice: java is a flat-container
  // target (srcfeature: false), so Main's blanket Copy carries
  // feature/SecretsFeature.java into the tree whenever tm/ holds it —
  // including for a model that never DECLARED the feature at all, which is
  // every project whose `target add` predates it or which dropped the
  // feature afterwards. Gating the method on the model (on ACTIVE or on
  // DECLARED, either way) leaves that copied source calling a method that
  // was never emitted, and javac — which does no dead-code elimination —
  // refuses the whole SDK on `cannot find symbol: featurePlugins`. An
  // always-present method costs one empty switch; a conditional one costs
  // the build.
  //
  // The SYMBOLS come from the ACTIVE view: an inactive feature's plugin
  // files were removed by the generate-time trim, so importing them would
  // be the same hard build failure from the other side.
  each(feature, (f: any) => {
    const syms: string[] = []
    each(f.plugin, (plugin: any) => {
      // Filter on `active` HERE rather than trusting the feature object to
      // arrive filtered (see Config_ts.pluginImports / Config_go): getting
      // this wrong emits an import for a class the trim just deleted, and
      // javac does no dead-code elimination — it is a hard build failure.
      if (false === plugin.active || null == plugin.active) return
      for (const [sym, one] of Object.entries(plugin.def?.java || {})) {
        // 'feature/secrets/sekreto/plugins/Hashicorp.java' -> the package
        // directory; 'Hashicorp.PLUGIN' -> the class to import.
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
    main: configDef.main,
    feature: featureConfig,
    options,
    entity: entityConfig,
  }

  // Config lives in the core package alongside the client.
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
