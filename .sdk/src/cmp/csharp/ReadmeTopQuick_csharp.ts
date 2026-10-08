
import { cmp, Content, isAuthActive, envName, canonKey, canonScalarKey, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { csVarName, csListMatch } from './utility_csharp'


// A type-correct C# literal for a param: numeric/boolean/array/object params
// render a typed literal; strings render the quoted placeholder. The SDK's
// loose object model means all values live in Dictionary<string, object?>.
function csLit(type: any, placeholder: string = 'example'): string {
  const k = canonScalarKey(type)
  if ('NULL' === k) return 'null'
  if ('INTEGER' === k) return '1L'
  if ('NUMBER' === k) return '1.0'
  if ('BOOLEAN' === k) return 'true'
  if ('ARRAY' === k) return 'new List<object?>()'
  if ('OBJECT' === k) return 'new Dictionary<string, object?>()'
  return `"${placeholder}"`
}


const ReadmeTopQuick = cmp(function ReadmeTopQuick(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)

  const exampleEntity = Object.values(entity).find((e: any) => e.active !== false) as any

  const authActive = isAuthActive(model)
  const ctor = authActive
    ? `new ${model.const.Name}SDK(new Dictionary<string, object?>\n{\n    ["apikey"] = Environment.GetEnvironmentVariable("${envName(model)}_APIKEY"),\n})`
    : `new ${model.const.Name}SDK()`

  const shown = null != exampleEntity &&
    ['list', 'load'].some((op: string) => Object.keys(exampleEntity.op || {}).includes(op))

  Content(`\`\`\`csharp
using ${model.const.Name}Sdk;
${shown ? 'using Voxgig.Struct;\n' : ''}
var client = ${ctor};

`)

  if (exampleEntity) {
    const eName = nom(exampleEntity, 'Name')
    // Sanitise the local variable name — an entity whose camelCased name is a
    // C# keyword gets a trailing underscore (csVarName) so the snippet compiles.
    const eVar = csVarName(exampleEntity.name)
    const opnames = Object.keys(exampleEntity.op || {})
    const idF = entityIdField(exampleEntity)

    if (opnames.includes('list')) {
      Content(`// List all ${eName.toLowerCase()}s (a list of entities, one per record, as object?; raises on error)
var ${eVar}List = (List<object?>)client.${eName}().List(${csListMatch(exampleEntity)})!;
foreach (var ${eVar}Item in ${eVar}List)
{
    Console.WriteLine(StructUtils.Jsonify(((IEntity)${eVar}Item!).Data()));
}
`)
    }

    if (opnames.includes('load')) {
      // Every REQUIRED load-match key (id first, then parent path params like
      // page_id) — the same shape the runtime resolves path params from, so
      // the example always works.
      const loadItems = opRequestShape(exampleEntity, 'load').items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      const loadArg = 0 < loadItems.length
        ? `new Dictionary<string, object?> {${loadItems.map((it: any) =>
          ` ["${it.name}"] = ${csLit(it.type,
            it.name === idF ? 'example_id' : 'example_' + it.name)}`).join(',')} }`
        : 'null'
      Content(`
// Load a specific ${eName.toLowerCase()} (returns the entity, raises on error)
var ${eVar} = (IEntity)client.${eName}().Load(${loadArg})!;
Console.WriteLine(StructUtils.Jsonify(${eVar}.Data()));
`)
    }
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopQuick
}
