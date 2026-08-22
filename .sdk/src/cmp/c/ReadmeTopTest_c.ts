
import { cmp, Content, canonKey, entityIdField, pickExampleEntity, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { cIdent, cVarName } from './utility_c'


// A type-correct C expression constructing a voxgig struct Value for a field's
// canonical type.
function cLit(type: any): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return 'v_num(1)'
  if ('BOOLEAN' === k) return 'v_bool(true)'
  if ('ARRAY' === k) return 'v_list()'
  if ('OBJECT' === k) return 'v_map()'
  return 'v_str("example")'
}


// cmap(...) for a set of pairs, or NULL when empty.
function cmapExpr(pairs: string[]): string {
  return pairs.length ? `cmap(${pairs.length}, ${pairs.join(', ')})` : 'NULL'
}


const ReadmeTopTest = cmp(function ReadmeTopTest(props: any) {
  const { target, ctx$: { model } } = props

  const ident = cIdent(model)
  const entity = getModelPath(model, `main.${KIT}.entity`)

  // Pick an entity with a real op (prefer a read op) — never fabricate a
  // `load` on an op-less entity.
  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)

  Content(`\`\`\`c
#include "core/api.h"

${model.const.Name}SDK* client = test_sdk(NULL, NULL);
PNError* err = NULL;
`)

  if (exampleEntity && primaryOp) {
    const eName = nom(exampleEntity, 'Name')
    const evar = cVarName(exampleEntity.name)
    const acc = `${ident}_${evar}`
    const idF = entityIdField(exampleEntity)
    const isMatchOp = 'load' === primaryOp || 'remove' === primaryOp
    let arg = 'NULL'
    if (isMatchOp) {
      // Every REQUIRED match key (id first) — the same shape that generates
      // the op's request match.
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      arg = cmapExpr(items.map((it: any) =>
        `"${it.name}", ${it.name === idF ? 'v_str("test01")' : cLit(it.type)}`))
    } else if ('create' === primaryOp || 'update' === primaryOp) {
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => it.name !== idF && it.name !== 'id')
      const required = items.filter((it: any) => !it.optional)
      const chosen = required.length ? required : items.slice(0, 3)
      arg = cmapExpr(chosen.map((it: any) => `"${it.name}", ${cLit(it.type)}`))
    }
    const resVar = cVarName(exampleEntity.name) + ('list' === primaryOp ? 's' : '_rec')
    Content(`Entity* ${evar} = ${acc}(client, NULL);
voxgig_value* ${resVar} = ${evar}->vt->${primaryOp}(${evar}, ${arg}, NULL, &err);
printf("%s\\n", voxgig_to_json(${resVar}));
`)
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopTest
}
