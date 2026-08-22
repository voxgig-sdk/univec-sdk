
import { cmp, Content, isAuthActive, envName, canonKey, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { cIdent, cVarName } from './utility_c'


// A type-correct C expression constructing a voxgig struct Value for a param.
// Strings render the quoted placeholder; numeric/boolean/array/object render a
// typed builder call.
function cLit(type: any, placeholder: string = 'example'): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return 'v_num(1)'
  if ('BOOLEAN' === k) return 'v_bool(true)'
  if ('ARRAY' === k) return 'v_list()'
  if ('OBJECT' === k) return 'v_map()'
  return `v_str("${placeholder}")`
}


// cmap(...) for a set of `"key", <lit>` pairs, or NULL when empty (ops accept
// a NULL match/data argument).
function cmapExpr(pairs: string[]): string {
  return pairs.length ? `cmap(${pairs.length}, ${pairs.join(', ')})` : 'NULL'
}


const ReadmeTopQuick = cmp(function ReadmeTopQuick(props: any) {
  const { target, ctx$: { model } } = props

  const ident = cIdent(model)
  const entity = getModelPath(model, `main.${KIT}.entity`)

  const exampleEntity = Object.values(entity).find((e: any) => e.active !== false) as any

  const authActive = isAuthActive(model)
  const ctor = authActive
    ? `${ident}_sdk_new(cmap(1,\n    "apikey", v_str(getenv("${envName(model)}_APIKEY"))))`
    : `${ident}_sdk_new(NULL)`

  Content(`\`\`\`c
#include "core/api.h"

${model.const.Name}SDK* client = ${ctor};
PNError* err = NULL;

`)

  if (exampleEntity) {
    const eName = nom(exampleEntity, 'Name')
    const evar = cVarName(exampleEntity.name)
    const acc = `${ident}_${evar}`
    const opnames = Object.keys(exampleEntity.op || {})
    // Model-driven id key: null when the entity has no id-like field, in which
    // case the load example takes no match argument.
    const idF = entityIdField(exampleEntity)

    if (opnames.includes('list')) {
      Content(`Entity* ${evar} = ${acc}(client, NULL);

// List all ${eName.toLowerCase()}s (returns a List, sets *err on failure)
voxgig_value* ${evar}s = ${evar}->vt->list(${evar}, NULL, NULL, &err);
for (size_t i = 0; i < (size_t)voxgig_size(${evar}s); i++) {
    printf("%s\\n", voxgig_to_json(voxgig_getelem(${evar}s, v_int(i), NULL)));
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
      const loadArg = cmapExpr(loadItems.map((it: any) =>
        `"${it.name}", ${cLit(it.type,
          it.name === idF ? 'example_id' : 'example_' + it.name)}`))
      const acquire = opnames.includes('list')
        ? ''
        : `Entity* ${evar} = ${acc}(client, NULL);\n`
      Content(`
${acquire}// Load a specific ${eName.toLowerCase()} (returns the record, sets *err on failure)
voxgig_value* ${evar}_rec = ${evar}->vt->load(${evar}, ${loadArg}, NULL, &err);
printf("%s\\n", voxgig_to_json(${evar}_rec));
`)
    }
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopQuick
}
