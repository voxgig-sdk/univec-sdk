
import { cmp, Content, isAuthActive, envName, canonKey, opRequestShape, entityIdField, entityOps } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { csVarName } from './utility_csharp'


const ReadmeQuick = cmp(function ReadmeQuick(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)

  const exampleEntity = Object.values(entity).find((e: any) => e.active !== false) as any

  // Find a nested entity if available: one with a parent chain
  // (relations.ancestors), an active load op, and a required non-id load
  // param to demonstrate (the parent key, e.g. page_id).
  const nestedEntity = Object.values(entity).find((e: any) =>
    e.active !== false &&
    e.relations && e.relations.ancestors && 0 < e.relations.ancestors.length &&
    entityOps(e).includes('load') &&
    opRequestShape(e, 'load').items.some((it: any) =>
      !it.optional && it.name !== entityIdField(e))
  ) as any

  const authActive = isAuthActive(model)
  const ctor = authActive
    ? `new ${model.const.Name}SDK(new Dictionary<string, object?>\n{\n    ["apikey"] = Environment.GetEnvironmentVariable("${envName(model)}_APIKEY"),\n})`
    : `new ${model.const.Name}SDK()`

  Content(`### 1. Create a client

\`\`\`csharp
using ${model.const.Name}Sdk;

var client = ${ctor};
\`\`\`

`)

  if (exampleEntity) {
    const eName = nom(exampleEntity, 'Name')
    const article = /^[aeiou]/i.test(eName) ? 'an' : 'a'
    // Sanitise the local variable name — a camelCased C# keyword gets a
    // trailing underscore (csVarName) so the snippet compiles.
    const eVar = csVarName(exampleEntity.name)
    const opnames = entityOps(exampleEntity)
    // Model-driven id key: `idF` is the entity's id-like MATCH field name, or
    // null when it has none.
    const idF = entityIdField(exampleEntity)

    // A type-correct C# literal for a param.
    const csLit = (type: any, placeholder: string = 'example'): string => {
      const k = canonKey(type)
      if ('INTEGER' === k) return '1L'
      if ('NUMBER' === k) return '1.0'
      if ('BOOLEAN' === k) return 'true'
      if ('ARRAY' === k) return 'new List<object?>()'
      if ('OBJECT' === k) return 'new Dictionary<string, object?>()'
      return `"${placeholder}"`
    }

    if (opnames.includes('list')) {
      Content(`### 2. List ${eName.toLowerCase()} records

\`List(null)\` returns an aggregate list of records (as \`object?\`) and raises
on error.

\`\`\`csharp
try
{
    var ${eVar}List = client.${eName}().List(null);
    Console.WriteLine(${eVar}List);
}
catch (Exception err)
{
    Console.WriteLine($"list failed: {err.Message}");
}
\`\`\`

`)
    }

    if (nestedEntity) {
      const neName = nom(nestedEntity, 'Name')
      const neArticle = /^[aeiou]/i.test(neName) ? 'an' : 'a'
      const neVar = csVarName(nestedEntity.name)

      // Model-driven match: every REQUIRED load-match key. Parent keys (e.g.
      // page_id) first, the entity's own id last.
      const neIdF = entityIdField(nestedEntity)
      const neRequired = opRequestShape(nestedEntity, 'load').items
        .filter((it: any) => !it.optional)
        .sort((a: any, b: any) =>
          (a.name === neIdF ? 1 : 0) - (b.name === neIdF ? 1 : 0))
      const parentItem = neRequired.find((it: any) => it.name !== neIdF) as any
      const parentParam = parentItem && parentItem.name
      const parentName = parentParam ? parentParam.replace(/_id$/, '') : 'its parent'
      const neMatch = neRequired.map((it: any) =>
        `["${it.name}"] = ${csLit(it.type,
          it.name === neIdF ? 'example_id' : 'example_' + it.name)}`)

      Content(`### 3. Load ${neArticle} ${neName.toLowerCase()}

${neName} is nested under ${parentName}, so provide the \`${parentParam}\`.
\`Load()\` returns the bare record (as \`object?\`) and raises on error.

\`\`\`csharp
try
{
    var ${neVar} = client.${neName}().Load(new Dictionary<string, object?> { ${neMatch.join(', ')} });
    Console.WriteLine(${neVar});
}
catch (Exception err)
{
    Console.WriteLine($"load failed: {err.Message}");
}
\`\`\`

`)
    }
    else if (opnames.includes('load')) {
      // Every REQUIRED load-match key (id first, then parent path params).
      const loadRequired = opRequestShape(exampleEntity, 'load').items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      const loadArg = 0 < loadRequired.length
        ? `new Dictionary<string, object?> {${loadRequired.map((it: any) =>
          ` ["${it.name}"] = ${csLit(it.type,
            it.name === idF ? 'example_id' : 'example_' + it.name)}`).join(',')} }`
        : 'null'

      Content(`### 3. Load ${article} ${eName.toLowerCase()}

\`Load()\` returns the bare record (as \`object?\`) and raises on error.

\`\`\`csharp
try
{
    var ${eVar} = client.${eName}().Load(${loadArg});
    Console.WriteLine(${eVar});
}
catch (Exception err)
{
    Console.WriteLine($"load failed: {err.Message}");
}
\`\`\`

`)
    }

    // Model-driven example fields: derive the create/update body from the op
    // shape (opRequestShape) so the docs reference REAL writable fields.
    const examplePairs = (opname: string): string[] => {
      const items = opRequestShape(exampleEntity, opname).items
        .filter((it: any) => (it.name !== idF && it.name !== 'id') ||
          ('create' === opname && !it.optional))
      const required = items.filter((it: any) => !it.optional)
      const optional = items.filter((it: any) => it.optional)
      const chosen = 'create' === opname
        ? (required.length ? required : items.slice(0, 2))
        : required.concat(optional).slice(0, Math.max(2, required.length))
      return chosen.map((it: any) => `["${it.name}"] = ${csLit(it.type, 'example_' + it.name)}`)
    }

    const idParamType = (opname: string): any => {
      const it = opRequestShape(exampleEntity, opname).items.find((x: any) => x.name === idF)
      return it && it.type
    }

    if (opnames.includes('create') || opnames.includes('update') || opnames.includes('remove')) {
      Content(`### 4. Create, update, and remove

\`\`\`csharp
`)
      if (opnames.includes('create')) {
        Content(`// Create — returns the bare created record (as object?)
var created = client.${eName}().Create(new Dictionary<string, object?> { ${examplePairs('create').join(', ')} });

`)
      }
      if (opnames.includes('update')) {
        const updatePairs = (idF ? [`["${idF}"] = ${csLit(idParamType('update'), 'example_id')}`] : [])
          .concat(examplePairs('update'))
        Content(`// Update — supply the id in the match/data
client.${eName}().Update(new Dictionary<string, object?> { ${updatePairs.join(', ')} });

`)
      }
      if (opnames.includes('remove')) {
        // Every REQUIRED remove-match key: the id plus parent keys like page_id.
        const removePairs = opRequestShape(exampleEntity, 'remove').items
          .filter((it: any) => !it.optional || it.name === idF)
          .sort((a: any, b: any) =>
            (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
          .map((it: any) => it.name === idF
            ? `["${it.name}"] = ${csLit(idParamType('remove'), 'example_id')}`
            : `["${it.name}"] = ${csLit(it.type, 'example_' + it.name)}`)
        Content(`// Remove
client.${eName}().Remove(${removePairs.length ? `new Dictionary<string, object?> { ${removePairs.join(', ')} }` : 'null'});
`)
      }
      Content(`\`\`\`

`)
    }
  }
})


export {
  ReadmeQuick
}
