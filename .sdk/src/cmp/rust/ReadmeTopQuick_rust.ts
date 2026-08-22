
import { cmp, Content, isAuthActive, envName, canonKey, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { crateIdent, rustVarName } from './utility_rust'


// A type-correct rust expression constructing a voxgig struct Value for a
// param. Strings render the quoted placeholder; numeric/boolean/array/object
// render a typed literal.
function rustLit(type: any, placeholder: string = 'example'): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return 'Value::Num(1.0)'
  if ('BOOLEAN' === k) return 'Value::Bool(true)'
  if ('ARRAY' === k) return 'Value::empty_list()'
  if ('OBJECT' === k) return 'Value::empty_map()'
  return `Value::str("${placeholder}")`
}


const ReadmeTopQuick = cmp(function ReadmeTopQuick(props: any) {
  const { target, ctx$: { model } } = props

  const rustcrate = crateIdent(model)
  const entity = getModelPath(model, `main.${KIT}.entity`)

  const exampleEntity = Object.values(entity).find((e: any) => e.active !== false) as any

  const authActive = isAuthActive(model)
  const ctor = authActive
    ? `${model.const.Name}SDK::new(jo(vec![\n    ("apikey", Value::str(std::env::var("${envName(model)}_APIKEY").unwrap_or_default())),\n]))`
    : `${model.const.Name}SDK::new(Value::Noval)`

  Content(`\`\`\`rust
use ${rustcrate}::{jo, ${model.const.Name}SDK, Value};

let client = ${ctor};

`)

  if (exampleEntity) {
    const eName = nom(exampleEntity, 'Name')
    const eVar = rustVarName(exampleEntity.name)
    const method = rustVarName(exampleEntity.name)
    const opnames = Object.keys(exampleEntity.op || {})
    // Model-driven id key: null when the entity has no id-like field, in which
    // case the load example takes no match argument.
    const idF = entityIdField(exampleEntity)

    if (opnames.includes('list')) {
      Content(`// List all ${eName.toLowerCase()}s (returns a Value::List, Err on failure)
let ${eVar}s = client.${method}(Value::Noval).list(Value::Noval, Value::Noval).unwrap();
if let Value::List(items) = &${eVar}s {
    for ${eVar} in items.borrow().iter() {
        println!("{:?}", ${eVar});
    }
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
        ? `jo(vec![${loadItems.map((it: any) =>
          `("${it.name}", ${rustLit(it.type,
            it.name === idF ? 'example_id' : 'example_' + it.name)})`).join(', ')}])`
        : 'Value::Noval'
      Content(`
// Load a specific ${eName.toLowerCase()} (returns the record, Err on failure)
let ${eVar} = client.${method}(Value::Noval).load(${loadArg}, Value::Noval).unwrap();
println!("{:?}", ${eVar});
`)
    }
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopQuick
}
