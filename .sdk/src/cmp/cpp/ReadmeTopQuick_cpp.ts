
import { cmp, Content, isAuthActive, envName, canonKey, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { cppVarName } from './utility_cpp'


// A type-correct C++ literal for a param.
function cppLit(type: any, placeholder: string = 'example'): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return 'Value(1)'
  if ('BOOLEAN' === k) return 'Value(true)'
  if ('ARRAY' === k) return 'vlist()'
  if ('OBJECT' === k) return 'vmap()'
  return `Value("${placeholder}")`
}


const ReadmeTopQuick = cmp(function ReadmeTopQuick(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)

  const exampleEntity = Object.values(entity).find((e: any) => e.active !== false) as any

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

  Content(`\`\`\`cpp
${ctorIncludes}

using namespace sdk;

${ctor}

`)

  if (exampleEntity) {
    const acc = cppVarName(exampleEntity.name)
    const eVar = acc
    const opnames = Object.keys(exampleEntity.op || {})
    // Model-driven id key: null when the entity has no id-like field.
    const idF = entityIdField(exampleEntity)

    if (opnames.includes('list')) {
      Content(`// List all ${acc}s (returns a Value list, throws on error)
Value ${eVar}s = client->${acc}()->list(Value::undef(), Value::undef());
for (const auto& ${eVar} : *${eVar}s.as_list()) {
  std::cout << Struct::jsonify(${eVar}) << std::endl;
}
`)
    }

    if (opnames.includes('load')) {
      // Every REQUIRED load-match key (id first, then parent path params).
      const loadItems = opRequestShape(exampleEntity, 'load').items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      const loadArg = 0 < loadItems.length
        ? `vmap({${loadItems.map((it: any) =>
          `{"${it.name}", ${cppLit(it.type,
            it.name === idF ? 'example_id' : 'example_' + it.name)}}`).join(', ')}})`
        : 'Value::undef()'
      Content(`
// Load a specific ${acc} (returns the record, throws on error)
Value ${eVar} = client->${acc}()->load(${loadArg}, Value::undef());
std::cout << Struct::jsonify(${eVar}) << std::endl;
`)
    }
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopQuick
}
