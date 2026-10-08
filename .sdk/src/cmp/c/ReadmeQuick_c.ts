
import { cmp, Content, isAuthActive, envName, canonKey, canonScalarKey, opRequestShape, entityIdField, entityDataIdField, entityOps } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { cIdent, cVarName, cListMatch } from './utility_c'


const ReadmeQuick = cmp(function ReadmeQuick(props: any) {
  const { target, ctx$: { model } } = props

  const ident = cIdent(model)
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
    ? `${ident}_sdk_new(cmap(1,\n    "apikey", v_str(getenv("${envName(model)}_APIKEY"))))`
    : `${ident}_sdk_new(NULL)`

  // A type-correct C expression constructing a voxgig struct Value.
  const cLit = (type: any, placeholder: string = 'example'): string => {
    const k = canonScalarKey(type)
    if ('NULL' === k) return 'v_null()'
    if ('INTEGER' === k || 'NUMBER' === k) return 'v_num(1)'
    if ('BOOLEAN' === k) return 'v_bool(true)'
    if ('ARRAY' === k) return 'v_list()'
    if ('OBJECT' === k) return 'v_map()'
    return `v_str("${placeholder}")`
  }

  // cmap(...) for a set of pairs, or NULL when empty.
  const cmapExpr = (pairs: string[]): string =>
    pairs.length ? `cmap(${pairs.length}, ${pairs.join(', ')})` : 'NULL'

  Content(`### 1. Create a client

\`\`\`c
#include "core/api.h"

${model.const.Name}SDK* client = ${ctor};
PNError* err = NULL;
\`\`\`

`)

  if (exampleEntity) {
    const eName = nom(exampleEntity, 'Name')
    const article = /^[aeiou]/i.test(eName) ? 'an' : 'a'
    const evar = cVarName(exampleEntity.name)
    const acc = `${ident}_${evar}`
    const opnames = entityOps(exampleEntity)
    // Model-driven id key: `idF` is the entity's id-like MATCH field name, or
    // null. `dataIdF` is the id on the RETURNED record's data type.
    const idF = entityIdField(exampleEntity)
    const dataIdF = entityDataIdField(exampleEntity)

    if (opnames.includes('list')) {
      Content(`### 2. List ${eName.toLowerCase()} records

\`list()\` returns a \`NULL\`-terminated array of entities, one per record,
and sets \`*err\` on failure — check \`err\` after the call. \`vt->data\`
reads an entity's record.

\`\`\`c
Entity* ${evar} = ${acc}(client, NULL);
Entity** ${evar}s = ${evar}->vt->list(${evar}, ${cListMatch(exampleEntity)}, NULL, &err);
if (err) {
    fprintf(stderr, "list failed: %s\\n", err->msg);
} else {
    for (size_t i = 0; ${evar}s[i]; i++) {
        printf("%s\\n", voxgig_to_json(${evar}s[i]->vt->data(${evar}s[i], NULL)));
    }
}
\`\`\`

`)
    }

    if (nestedEntity) {
      const neName = nom(nestedEntity, 'Name')
      const neArticle = /^[aeiou]/i.test(neName) ? 'an' : 'a'
      const neVar = cVarName(nestedEntity.name)
      const neAcc = `${ident}_${neVar}`

      const neIdF = entityIdField(nestedEntity)
      const neRequired = opRequestShape(nestedEntity, 'load').items
        .filter((it: any) => !it.optional)
        .sort((a: any, b: any) =>
          (a.name === neIdF ? 1 : 0) - (b.name === neIdF ? 1 : 0))
      const parentItem = neRequired.find((it: any) => it.name !== neIdF) as any
      const parentParam = parentItem && parentItem.name
      const parentName = parentParam ? parentParam.replace(/_id$/, '') : 'its parent'
      const neMatch = cmapExpr(neRequired.map((it: any) =>
        `"${it.name}", ${cLit(it.type,
          it.name === neIdF ? 'example_id' : 'example_' + it.name)}`))

      Content(`### 3. Load ${neArticle} ${neName.toLowerCase()}

${neName} is nested under ${parentName}, so provide the \`${parentParam}\`.
\`load()\` returns the entity and sets \`*err\` on failure; \`vt->data\` reads
its record.

\`\`\`c
Entity* ${neVar} = ${neAcc}(client, NULL);
Entity* loaded = ${neVar}->vt->load(${neVar}, ${neMatch}, NULL, &err);
if (err) {
    fprintf(stderr, "load failed: %s\\n", err->msg);
} else {
    printf("%s\\n", voxgig_to_json(loaded->vt->data(loaded, NULL)));
}
\`\`\`

`)
    }
    else if (opnames.includes('load')) {
      const loadRequired = opRequestShape(exampleEntity, 'load').items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      const loadArg = cmapExpr(loadRequired.map((it: any) =>
        `"${it.name}", ${cLit(it.type,
          it.name === idF ? 'example_id' : 'example_' + it.name)}`))
      const acquire = opnames.includes('list')
        ? ''
        : `Entity* ${evar} = ${acc}(client, NULL);\n`

      Content(`### 3. Load ${article} ${eName.toLowerCase()}

\`load()\` returns the entity and sets \`*err\` on failure; \`vt->data\` reads
its record.

\`\`\`c
${acquire}Entity* loaded = ${evar}->vt->load(${evar}, ${loadArg}, NULL, &err);
if (err) {
    fprintf(stderr, "load failed: %s\\n", err->msg);
} else {
    printf("%s\\n", voxgig_to_json(loaded->vt->data(loaded, NULL)));
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
      return chosen.map((it: any) => `"${it.name}", ${cLit(it.type, 'example_' + it.name)}`)
    }

    const idParamType = (opname: string): any => {
      const it = opRequestShape(exampleEntity, opname).items.find((x: any) => x.name === idF)
      return it && it.type
    }
    // The id VALUE for an update/remove match: `created_id`, read off the
    // created entity's record, when its data type carries the id AND a create
    // ran; otherwise a type-correct literal.
    const readsId = null != dataIdF && opnames.includes('create')
    const idValueFor = (opname: string): string => readsId
      ? 'created_id'
      : cLit(idParamType(opname), 'example_id')

    if (opnames.includes('create') || opnames.includes('update') || opnames.includes('patch') ||
      opnames.includes('remove')) {
      const acquire = (opnames.includes('list') || opnames.includes('load'))
        ? ''
        : `Entity* ${evar} = ${acc}(client, NULL);\n`
      Content(`### 4. Create, update, and remove

\`\`\`c
${acquire}`)
      if (opnames.includes('create')) {
        const idLine = readsId && (opnames.includes('update') || opnames.includes('remove'))
          ? `voxgig_value* created_id = created
    ? getp(created->vt->data(created, NULL), "${dataIdF}") : v_undef();
`
          : ''
        Content(`// Create — returns the created entity, or NULL with *err set
Entity* created = ${evar}->vt->create(${evar}, ${cmapExpr(examplePairs('create'))}, NULL, &err);
${idLine}
`)
      }
      if (opnames.includes('update')) {
        const updatePairs = (idF ? [`"${idF}", ${idValueFor('update')}`] : []).concat(examplePairs('update'))
        Content(`// Update
${evar}->vt->update(${evar}, ${cmapExpr(updatePairs)}, NULL, &err);

`)
      }
      if (opnames.includes('patch')) {
        const patchPairs = (idF ? [`"${idF}", ${idValueFor('patch')}`] : []).concat(examplePairs('patch'))
        Content(`// Patch — sends only the fields given
${evar}->vt->patch(${evar}, ${cmapExpr(patchPairs)}, NULL, &err);

`)
      }
      if (opnames.includes('remove')) {
        const removePairs = opRequestShape(exampleEntity, 'remove').items
          .filter((it: any) => !it.optional || it.name === idF)
          .sort((a: any, b: any) =>
            (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
          .map((it: any) => it.name === idF
            ? `"${it.name}", ${idValueFor('remove')}`
            : `"${it.name}", ${cLit(it.type, 'example_' + it.name)}`)
        Content(`// Remove
${evar}->vt->remove(${evar}, ${cmapExpr(removePairs)}, NULL, &err);
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
