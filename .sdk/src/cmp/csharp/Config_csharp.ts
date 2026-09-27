
import {
  Content,
  File,
  cmp,
  configDefinition,
  configReprSetting,
  each,
  isAuthActive,
  isConfigData,
  resolveAuthIn,
  resolveAuthName,
  targetFeatures,
} from '@voxgig/sdkgen'


import {
  KIT,
  Model,
  getModelPath,
} from '@voxgig/apidef'


import {
  csStringLiteral,
  formatCsMap,
} from './utility_csharp'


// Generates core/Config.cs: the static SdkConfig class holding the
// generated model config (MakeConfig) and the by-name feature factory
// (MakeFeature). N-feature-safe: both are emitted per feature entry in the
// model, so any number of features works.
const Config = cmp(async function Config(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model

  // Gated by the applicability tags, so this target never imports or
  // registers a feature it has no source for. One rule, one place:
  // helpers/applicability.
  const feature = targetFeatures(model, target)

  const { def: configDef, json: baseJson } = configDefinition(model, target.name)

  const authIn = resolveAuthIn(model)
  const authName = resolveAuthName(model)
  let configJson = baseJson

  if (isAuthActive(model) && null != configDef.options && null != configDef.options.auth) {
    let changed = false
    if ('header' !== authIn) {
      configDef.options.auth.in = authIn
      changed = true
    }
    if ('Authorization' !== authName) {
      configDef.options.auth.name = authName
      changed = true
    }
    if (changed) {
      configJson = JSON.stringify(configDef)
    }
  }

  const asData = isConfigData(configJson, configReprSetting(model))

  const featurePlugins: Record<string, string[]> = {}

  each(feature, (f: any) => {
    const syms: string[] = []
    each(f.plugin, (plugin: any) => {
      // Filter on `active` HERE rather than trusting the feature object to
      // arrive filtered (see Config_go: getting this wrong emits a
      // reference to a file the plugin trim has just deleted, and the SDK
      // does not compile).
      if (false === plugin.active || null == plugin.active) return
      for (const sym of Object.keys(plugin.def?.csharp || {})) {
        syms.push(sym)
      }
    })
    if (0 < syms.length) {
      featurePlugins[f.name] = syms.sort()
    }
  })

  const featurePluginCases = Object.keys(featurePlugins).sort()
    .map((fname: string) =>
      `            case ${JSON.stringify(fname)}:
                return new List<object?>
                {
` + featurePlugins[fname]
        .map((sym: string) => `                    global::Voxgig.Sekreto.Plugins.${sym},
`).join('') +
      `                };
`).join('')

  File({ name: 'Config.' + target.ext }, () => {

    Content(`// ${model.const.Name} SDK - generated model configuration and feature
// factory. GENERATED from the API model - do not edit by hand.
${asData ? '\nusing System.Text.Json;\n' : ''}
namespace ${model.const.Name}Sdk;

public static class SdkConfig
{
`)

    if (asData) {
      Content(`    // THE API MODEL, EMBEDDED AS DATA (sdkgen rung L1).
    //
    // Emitted only above a size threshold, or when \`main.kit.config.repr\`
    // pins it: for a small model the literal is smaller and far easier to
    // read when debugging.
    private const string ConfigData = ${csStringLiteral(configJson)};

    // Boxed numerics compare by exact type - (object)5L does not Equals
    // (object)5 - and MakeConfig is public API consumers read numbers out of,
    // so the two representations must not disagree about the type of a whole
    // number just because the model crossed a size threshold. This ladder
    // (int, else long, else double) is exactly what the literal branch emits;
    // see formatCsNumber in the generator.
    //
    // Deliberately NOT SdkUtility.JsonToNative: that helper's conditional
    // operator gives \`TryGetInt64(out var l) ? l : el.GetDouble()\` the common
    // type double, so it boxes every whole number as a double regardless of
    // its own doc comment. Reusing it here would make the data branch
    // disagree with the literal on every integer in the model.
    private static object? ConfigValue(JsonElement el)
    {
        switch (el.ValueKind)
        {
            case JsonValueKind.Object:
            {
                var map = new Dictionary<string, object?>();
                foreach (var prop in el.EnumerateObject())
                {
                    map[prop.Name] = ConfigValue(prop.Value);
                }
                return map;
            }

            case JsonValueKind.Array:
            {
                var list = new List<object?>();
                foreach (var item in el.EnumerateArray())
                {
                    list.Add(ConfigValue(item));
                }
                return list;
            }

            case JsonValueKind.String:
                return el.GetString();

            case JsonValueKind.Number:
                if (el.TryGetInt32(out var i))
                {
                    return i;
                }
                if (el.TryGetInt64(out var l))
                {
                    return l;
                }
                return el.GetDouble();

            case JsonValueKind.True:
                return true;

            case JsonValueKind.False:
                return false;

            default:
                return null;
        }
    }

    // Parses a fresh, fully materialised config dictionary. Every call
    // re-parses, so hold the result if you need it more than once.
    public static Dictionary<string, object?> MakeConfig()
    {
        return ConfigValue(JsonSerializer.Deserialize<JsonElement>(ConfigData))
            as Dictionary<string, object?>
            ?? new Dictionary<string, object?>();
    }
`)
    }
    else {
      Content(`    public static Dictionary<string, object?> MakeConfig()
    {
        return ${formatCsMap(configDef, 2)};
    }
`)
    }

    Content(`
    private static readonly Lazy<Dictionary<string, object?>> SharedConfigVal =
        new(MakeConfig);

    // The process-wide config, built once on first use.
    //
    // The returned dictionary is SHARED: treat it as read-only. Callers that
    // need to mutate should use MakeConfig, which always returns a fresh copy.
    public static Dictionary<string, object?> SharedConfig()
    {
        return SharedConfigVal.Value;
    }
`)

    Content(`
    public static List<object?> FeaturePlugins(string name)
    {
        switch (name)
        {
${featurePluginCases}            default:
                return new List<object?>();
        }
    }
`)

    Content(`
    public static Feature.BaseFeature MakeFeature(string name)
    {
        switch (name)
        {
`)

    each(feature, (f: any) => {
      const fname = f.name.charAt(0).toUpperCase() + f.name.slice(1)
      if (f.name !== 'base') {
        Content(`            case "${f.name}":
                return new Feature.${fname}Feature();
`)
      }
    })

    Content(`            default:
                return new Feature.BaseFeature();
        }
    }
}
`)
  })
})


export {
  Config
}
