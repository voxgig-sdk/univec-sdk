
import {
  Content,
  File,
  cmp,
  configDefinition,
  configReprSetting,
  each,
  isConfigData,
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

  const feature = getModelPath(model, `main.${KIT}.feature`)

  // The same config as an OBJECT, built by the shared helper so this target's
  // literal and the data that replaces it above the threshold are the same
  // config by construction. The JSON is what the threshold is measured on -
  // emitted source size varies by language, the model does not.
  //
  // Passing target.name opts this target into main.slug / main.version /
  // main.target (the three station descriptor fields, station design §4):
  // both reps flow from this one call - the literal via formatCsMap(configDef)
  // and the data rep via csStringLiteral(configJson) - so they cannot
  // disagree on identity (mirrors Config_ts's #MainMeta block).
  const { def: configDef, json: configJson } = configDefinition(model, target.name)
  const asData = isConfigData(configJson, configReprSetting(model))

  File({ name: 'Config.' + target.ext }, () => {

    Content(`// ${model.const.Name} SDK - generated model configuration and feature
// factory. GENERATED from the API model - do not edit by hand.
${asData ? '\nusing System.Text.Json;\n' : ''}
namespace ${model.const.Name}Sdk;

public static class SdkConfig
{
`)

    // ABOVE THE THRESHOLD: emit the model as DATA.
    //
    // A composite Dictionary literal is a single expression the C# compiler
    // must bind, type and lower node by node, and every entry becomes IL the
    // JIT executes on first call. A string constant is one token, and
    // System.Text.Json builds the same dictionary from it far faster.
    //
    // JSON.stringify output is ALMOST a valid C# string literal: every escape
    // it emits (\\", \\\\, \\b, \\f, \\n, \\r, \\t, \\uXXXX) means the same thing in C#,
    // and it never emits \\/ or \\0, neither of which C# would accept. What it
    // does leave raw is U+0085/U+2028/U+2029, which C# counts as line
    // terminators and forbids inside a quoted literal - hence csStringLiteral.
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

    // SHARED CONFIG (sdkgen rung L2).
    //
    // The SDK reads the config on every request and never writes to it, so one
    // instance is shared by every client rather than rebuilt per client. Above
    // the size threshold MakeConfig re-parses the whole embedded JSON, so this
    // is the difference between parsing the model once per process and once
    // per client.
    //
    // Lazy<T> defaults to ExecutionAndPublication, so concurrent first calls
    // build it exactly once - the C# twin of go's sync.Once.
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
