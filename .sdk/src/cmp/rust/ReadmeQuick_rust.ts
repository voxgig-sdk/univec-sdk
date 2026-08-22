
import { cmp, Content, isAuthActive, envName, canonKey, opRequestShape, entityIdField, entityDataIdField, entityOps } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { crateIdent, rustVarName } from './utility_rust'


const ReadmeQuick = cmp(function ReadmeQuick(props: any) {
  const { target, ctx$: { model } } = props

  const rustcrate = crateIdent(model)
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
    ? `${model.const.Name}SDK::new(jo(vec![\n    ("apikey", Value::str(std::env::var("${envName(model)}_APIKEY").unwrap_or_default())),\n]))`
    : `${model.const.Name}SDK::new(Value::Noval)`

  // A type-correct rust expression constructing a voxgig struct Value.
  const rustLit = (type: any, placeholder: string = 'example'): string => {
    const k = canonKey(type)
    if ('INTEGER' === k || 'NUMBER' === k) return 'Value::Num(1.0)'
    if ('BOOLEAN' === k) return 'Value::Bool(true)'
    if ('ARRAY' === k) return 'Value::empty_list()'
    if ('OBJECT' === k) return 'Value::empty_map()'
    return `Value::str("${placeholder}")`
  }

  Content(`### 1. Create a client

\`\`\`rust
use ${rustcrate}::{getp, jo, ${model.const.Name}SDK, Value};

let client = ${ctor};
\`\`\`

`)

  if (exampleEntity) {
    const eName = nom(exampleEntity, 'Name')
    const article = /^[aeiou]/i.test(eName) ? 'an' : 'a'
    const eVar = rustVarName(exampleEntity.name)
    const method = rustVarName(exampleEntity.name)
    const opnames = entityOps(exampleEntity)
    // Model-driven id key: `idF` is the entity's id-like MATCH field name, or
    // null. `dataIdF` is the id on the RETURNED record's data type.
    const idF = entityIdField(exampleEntity)
    const dataIdF = entityDataIdField(exampleEntity)

    if (opnames.includes('list')) {
      Content(`### 2. List ${eName.toLowerCase()} records

\`list()\` returns a \`Value::List\` of records and returns \`Err\` on
failure — match on the \`Result\`.

\`\`\`rust
match client.${method}(Value::Noval).list(Value::Noval, Value::Noval) {
    Ok(${eVar}s) => {
        if let Value::List(items) = &${eVar}s {
            for ${eVar} in items.borrow().iter() {
                println!("{:?}", ${eVar});
            }
        }
    }
    Err(err) => eprintln!("list failed: {}", err),
}
\`\`\`

`)
    }

    if (nestedEntity) {
      const neName = nom(nestedEntity, 'Name')
      const neArticle = /^[aeiou]/i.test(neName) ? 'an' : 'a'
      const neVar = rustVarName(nestedEntity.name)
      const neMethod = rustVarName(nestedEntity.name)

      const neIdF = entityIdField(nestedEntity)
      const neRequired = opRequestShape(nestedEntity, 'load').items
        .filter((it: any) => !it.optional)
        .sort((a: any, b: any) =>
          (a.name === neIdF ? 1 : 0) - (b.name === neIdF ? 1 : 0))
      const parentItem = neRequired.find((it: any) => it.name !== neIdF) as any
      const parentParam = parentItem && parentItem.name
      const parentName = parentParam ? parentParam.replace(/_id$/, '') : 'its parent'
      const neMatch = neRequired.map((it: any) =>
        `("${it.name}", ${rustLit(it.type,
          it.name === neIdF ? 'example_id' : 'example_' + it.name)})`)

      Content(`### 3. Load ${neArticle} ${neName.toLowerCase()}

${neName} is nested under ${parentName}, so provide the \`${parentParam}\`.
\`load()\` returns the bare record and returns \`Err\` on failure.

\`\`\`rust
match client.${neMethod}(Value::Noval).load(jo(vec![${neMatch.join(', ')}]), Value::Noval) {
    Ok(${neVar}) => println!("{:?}", ${neVar}),
    Err(err) => eprintln!("load failed: {}", err),
}
\`\`\`

`)
    }
    else if (opnames.includes('load')) {
      const loadRequired = opRequestShape(exampleEntity, 'load').items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      const loadArg = 0 < loadRequired.length
        ? `jo(vec![${loadRequired.map((it: any) =>
          `("${it.name}", ${rustLit(it.type,
            it.name === idF ? 'example_id' : 'example_' + it.name)})`).join(', ')}])`
        : 'Value::Noval'

      Content(`### 3. Load ${article} ${eName.toLowerCase()}

\`load()\` returns the bare record and returns \`Err\` on failure.

\`\`\`rust
match client.${method}(Value::Noval).load(${loadArg}, Value::Noval) {
    Ok(${eVar}) => println!("{:?}", ${eVar}),
    Err(err) => eprintln!("load failed: {}", err),
}
\`\`\`

`)
    }

    // Model-driven example fields: derive the create/update body from the op
    // shape so the docs reference REAL writable fields.
    const examplePairs = (opname: string): string[] => {
      const items = opRequestShape(exampleEntity, opname).items
        .filter((it: any) => (it.name !== idF && it.name !== 'id') ||
          ('create' === opname && !it.optional))
      const required = items.filter((it: any) => !it.optional)
      const optional = items.filter((it: any) => it.optional)
      const chosen = 'create' === opname
        ? (required.length ? required : items.slice(0, 2))
        : required.concat(optional).slice(0, Math.max(2, required.length))
      return chosen.map((it: any) => `("${it.name}", ${rustLit(it.type, 'example_' + it.name)})`)
    }

    const idParamType = (opname: string): any => {
      const it = opRequestShape(exampleEntity, opname).items.find((x: any) => x.name === idF)
      return it && it.type
    }
    // The id VALUE for an update/remove match: read it off the returned
    // `created` record with getp when its data type carries the id AND a
    // create ran; otherwise a type-correct literal.
    const idValueFor = (opname: string): string => (null != dataIdF && opnames.includes('create'))
      ? `getp(&created, "${dataIdF}")`
      : rustLit(idParamType(opname), 'example_id')

    if (opnames.includes('create') || opnames.includes('update') || opnames.includes('remove')) {
      Content(`### 4. Create, update, and remove

\`\`\`rust
`)
      if (opnames.includes('create')) {
        Content(`// Create — returns the bare created record
let created = client.${method}(Value::Noval).create(jo(vec![${examplePairs('create').join(', ')}]), Value::Noval).unwrap();

`)
      }
      if (opnames.includes('update')) {
        const updatePairs = (idF ? [`("${idF}", ${idValueFor('update')})`] : []).concat(examplePairs('update'))
        Content(`// Update
client.${method}(Value::Noval).update(jo(vec![${updatePairs.join(', ')}]), Value::Noval).unwrap();

`)
      }
      if (opnames.includes('remove')) {
        const removePairs = opRequestShape(exampleEntity, 'remove').items
          .filter((it: any) => !it.optional || it.name === idF)
          .sort((a: any, b: any) =>
            (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
          .map((it: any) => it.name === idF
            ? `("${it.name}", ${idValueFor('remove')})`
            : `("${it.name}", ${rustLit(it.type, 'example_' + it.name)})`)
        Content(`// Remove
client.${method}(Value::Noval).remove(${removePairs.length ? `jo(vec![${removePairs.join(', ')}])` : 'Value::Noval'}, Value::Noval).unwrap();
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
