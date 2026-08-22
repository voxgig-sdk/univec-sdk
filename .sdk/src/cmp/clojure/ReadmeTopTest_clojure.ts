
import { cmp, Content, canonKey, entityIdField, pickExampleEntity, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'


// A type-correct Clojure literal for a field's canonical type.
function cljLit(type: any): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return '1'
  if ('BOOLEAN' === k) return 'true'
  if ('ARRAY' === k) return '(vs/jt)'
  if ('OBJECT' === k) return '(vs/jm)'
  return '"example"'
}


const ReadmeTopTest = cmp(function ReadmeTopTest(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)
  // Pick an entity with a real op (prefer a read op) — never fabricate a
  // `load` on an op-less entity.
  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)

  Content(`\`\`\`clojure
(require '[sdk.api :as api]
`)
  if (exampleEntity && primaryOp) {
    Content(`         '[sdk.entity.${exampleEntity.name} :as e-${exampleEntity.name}]
`)
  }
  Content(`         '[voxgig.struct :as vs])

(def client (api/test-sdk nil nil))
`)

  if (exampleEntity && primaryOp) {
    const eLow = exampleEntity.name
    const idF = entityIdField(exampleEntity)
    const isMatchOp = 'load' === primaryOp || 'remove' === primaryOp
    let arg = 'nil'
    if (isMatchOp) {
      // Every REQUIRED match key (id first) — the same shape that generates
      // the op's match handling.
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      arg = 0 < items.length
        ? `(vs/jm ${items.map((it: any) =>
          `"${it.name}" ${it.name === idF ? '"test01"' : cljLit(it.type)}`).join(' ')})`
        : 'nil'
    } else if ('create' === primaryOp || 'update' === primaryOp) {
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => it.name !== idF && it.name !== 'id')
      const required = items.filter((it: any) => !it.optional)
      const chosen = required.length ? required : items.slice(0, 3)
      arg = `(vs/jm ${chosen.map((it: any) => `"${it.name}" ${cljLit(it.type)}`).join(' ')})`
    }
    const eVar = eLow + ('list' === primaryOp ? 's' : '')
    Content(`(def ${eVar} (e-${eLow}/${primaryOp} (api/${eLow} client nil) ${arg} nil))
(println ${eVar})
`)
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopTest
}
