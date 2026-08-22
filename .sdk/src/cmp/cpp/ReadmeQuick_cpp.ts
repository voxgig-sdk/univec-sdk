
import { cmp, Content, isAuthActive, envName, canonKey, opRequestShape, entityIdField, entityDataIdField, entityOps } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { cppVarName } from './utility_cpp'


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

  const Name = model.const.Name
  const authActive = isAuthActive(model)
  const ctor = authActive
    ? `const char* apikey = std::getenv("${envName(model)}_APIKEY");
auto client = std::make_shared<${Name}SDK>(vmap({
    {"apikey", Value(apikey ? apikey : "")},
}));`
    : `auto client = ${Name}SDK::create();`
  const ctorIncludes = authActive
    ? `#include <cstdlib>
#include "core/sdk.hpp"`
    : `#include "core/sdk.hpp"`

  Content(`### 1. Create a client

\`\`\`cpp
${ctorIncludes}

using namespace sdk;

${ctor}
\`\`\`

`)

  // A type-correct C++ literal for a param: numeric/boolean/array/object
  // params render a typed sdk::Value; strings render the quoted placeholder.
  const cppLit = (type: any, placeholder: string = 'example'): string => {
    const k = canonKey(type)
    if ('INTEGER' === k || 'NUMBER' === k) return 'Value(1)'
    if ('BOOLEAN' === k) return 'Value(true)'
    if ('ARRAY' === k) return 'vlist()'
    if ('OBJECT' === k) return 'vmap()'
    return `Value("${placeholder}")`
  }

  if (exampleEntity) {
    const eName = nom(exampleEntity, 'Name')
    const article = /^[aeiou]/i.test(eName) ? 'an' : 'a'
    // The client accessor is the entity's snake_case name (client->planet()).
    const acc = cppVarName(exampleEntity.name)
    const eVar = acc
    const opnames = entityOps(exampleEntity)
    // Model-driven id key: `idF` is the entity's id-like MATCH field name, or
    // null when it has none. `dataIdF` is the id on the RETURNED record's data
    // type — an entity can key its match on an id it does not carry as data.
    const idF = entityIdField(exampleEntity)
    const dataIdF = entityDataIdField(exampleEntity)

    if (opnames.includes('list')) {
      Content(`### 2. List ${eName.toLowerCase()} records

\`list()\` returns an \`sdk::Value\` list and throws \`sdk::SdkErrorPtr\`
on error — iterate it directly.

\`\`\`cpp
try {
  Value ${eVar}s = client->${acc}()->list(Value::undef(), Value::undef());
  for (const auto& ${eVar} : *${eVar}s.as_list()) {
    std::cout << Struct::jsonify(${eVar}) << std::endl;
  }
} catch (const SdkErrorPtr& err) {
  std::cerr << "list failed: " << err->msg << std::endl;
}
\`\`\`

`)
    }

    if (nestedEntity) {
      const neName = nom(nestedEntity, 'Name')
      const neArticle = /^[aeiou]/i.test(neName) ? 'an' : 'a'
      const neAcc = cppVarName(nestedEntity.name)
      const neVar = neAcc

      // Model-driven match: every REQUIRED load-match key — the same shape
      // the runtime resolves path params from, so the example always works.
      // Parent keys (e.g. page_id) first, the entity's own id last.
      const neIdF = entityIdField(nestedEntity)
      const neRequired = opRequestShape(nestedEntity, 'load').items
        .filter((it: any) => !it.optional)
        .sort((a: any, b: any) =>
          (a.name === neIdF ? 1 : 0) - (b.name === neIdF ? 1 : 0))
      const parentItem = neRequired.find((it: any) => it.name !== neIdF) as any
      const parentParam = parentItem && parentItem.name
      const parentName = parentParam ? parentParam.replace(/_id$/, '') : 'its parent'
      const neMatch = neRequired.map((it: any) =>
        `{"${it.name}", ${cppLit(it.type,
          it.name === neIdF ? 'example_id' : 'example_' + it.name)}}`)

      Content(`### 3. Load ${neArticle} ${neName.toLowerCase()}

${neName} is nested under ${parentName}, so provide the \`${parentParam}\`.
\`load()\` returns the bare record and throws on error.

\`\`\`cpp
try {
  Value ${neVar} = client->${neAcc}()->load(vmap({${neMatch.join(', ')}}), Value::undef());
  std::cout << Struct::jsonify(${neVar}) << std::endl;
} catch (const SdkErrorPtr& err) {
  std::cerr << "load failed: " << err->msg << std::endl;
}
\`\`\`

`)
    }
    else if (opnames.includes('load')) {
      // Every REQUIRED load-match key (id first, then parent path params like
      // page_id) — the same shape the runtime resolves path params from.
      const loadRequired = opRequestShape(exampleEntity, 'load').items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      const loadArg = 0 < loadRequired.length
        ? `vmap({${loadRequired.map((it: any) =>
          `{"${it.name}", ${cppLit(it.type,
            it.name === idF ? 'example_id' : 'example_' + it.name)}}`).join(', ')}})`
        : 'Value::undef()'

      Content(`### 3. Load ${article} ${eName.toLowerCase()}

\`load()\` returns the bare record and throws on error.

\`\`\`cpp
try {
  Value ${eVar} = client->${acc}()->load(${loadArg}, Value::undef());
  std::cout << Struct::jsonify(${eVar}) << std::endl;
} catch (const SdkErrorPtr& err) {
  std::cerr << "load failed: " << err->msg << std::endl;
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
      return chosen.map((it: any) => `{"${it.name}", ${cppLit(it.type, 'example_' + it.name)}}`)
    }

    // The id VALUE for an update/remove match: read off the returned `created`
    // record only when its data type carries the id AND a create ran; otherwise
    // a type-correct literal.
    const idParamType = (opname: string): any => {
      const it = opRequestShape(exampleEntity, opname).items.find((x: any) => x.name === idF)
      return it && it.type
    }
    const idValueFor = (opname: string): string => (null != dataIdF && opnames.includes('create'))
      ? `getp(created, "${dataIdF}")`
      : cppLit(idParamType(opname), 'example_id')

    if (opnames.includes('create') || opnames.includes('update') || opnames.includes('remove')) {
      Content(`### 4. Create, update, and remove

\`\`\`cpp
`)
      if (opnames.includes('create')) {
        Content(`// Create — returns the bare created record.
Value created = client->${acc}()->create(vmap({${examplePairs('create').join(', ')}}), Value::undef());

`)
      }
      if (opnames.includes('update')) {
        const updatePairs = (idF ? [`{"${idF}", ${idValueFor('update')}}`] : []).concat(examplePairs('update'))
        const fromCreated = null != dataIdF && opnames.includes('create')
        Content(`// Update${fromCreated ? " — reuse the created record's id" : ''}
client->${acc}()->update(vmap({${updatePairs.join(', ')}}), Value::undef());

`)
      }
      if (opnames.includes('remove')) {
        // Every REQUIRED remove-match key: the id (off the created record
        // when possible) plus parent keys like page_id.
        const removePairs = opRequestShape(exampleEntity, 'remove').items
          .filter((it: any) => !it.optional || it.name === idF)
          .sort((a: any, b: any) =>
            (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
          .map((it: any) => it.name === idF
            ? `{"${it.name}", ${idValueFor('remove')}}`
            : `{"${it.name}", ${cppLit(it.type, 'example_' + it.name)}}`)
        Content(`// Remove
client->${acc}()->remove(${removePairs.length ? `vmap({${removePairs.join(', ')}})` : 'Value::undef()'}, Value::undef());
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
