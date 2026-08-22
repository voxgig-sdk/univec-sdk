
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


const ReadmeHowto = cmp(function ReadmeHowto(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)
  // Pick an entity with a real op (prefer a read op). primaryOp is null only
  // when NO entity exposes any op (a direct()-only SDK).
  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)
  const eLow = exampleEntity ? exampleEntity.name : 'entity'
  // Model-driven id key: null when the entity has no id-like field.
  const idF = exampleEntity ? entityIdField(exampleEntity) : null
  const isMatchOp = 'load' === primaryOp || 'remove' === primaryOp
  let testArg = 'nil'
  if (exampleEntity && isMatchOp) {
    testArg = idF ? `(vs/jm "${idF}" "test01")` : 'nil'
  } else if (exampleEntity && ('create' === primaryOp || 'update' === primaryOp)) {
    const items = opRequestShape(exampleEntity, primaryOp).items
      .filter((it: any) => it.name !== idF && it.name !== 'id')
    const required = items.filter((it: any) => !it.optional)
    const chosen = required.length ? required : items.slice(0, 3)
    testArg = `(vs/jm ${chosen.map((it: any) => `"${it.name}" ${cljLit(it.type)}`).join(' ')})`
  }

  // The op-driven test-mode line, shown only when the SDK has an entity op.
  const testModeExample = primaryOp
    ? `;; Entity ops return the bare record and raise on error.
(def ${eLow} (e-${eLow}/${primaryOp} (api/${eLow} client nil) ${testArg} nil))
;; ${eLow} contains the mock response record
(println ${eLow})`
    : `(def result (api/direct client (vs/jm "path" "/api/resource" "method" "GET")))
(println result)`

  const testModeRequire = primaryOp
    ? `\n         '[sdk.entity.${eLow} :as e-${eLow}]`
    : ''

  Content(`### Make a direct HTTP request

For endpoints not covered by entity operations:

\`\`\`clojure
(def result
  (api/direct client
    (vs/jm "path" "/api/resource/{id}"
           "method" "GET"
           "params" (vs/jm "id" "example"))))

(if (vs/getprop result "ok")
  (do
    (println (vs/getprop result "status"))  ;; 200
    (println (vs/getprop result "data")))   ;; response body
  ;; A non-2xx response carries status + data (the error body); a
  ;; transport-level failure carries err instead. Only one is present.
  (println (vs/getprop result "status") (vs/getprop result "err")))
\`\`\`

### Prepare a request without sending it

\`\`\`clojure
;; prepare returns the fetch definition and raises on error.
(def fetchdef
  (api/prepare client
    (vs/jm "path" "/api/resource/{id}"
           "method" "DELETE"
           "params" (vs/jm "id" "example"))))

(println (vs/getprop fetchdef "url"))
(println (vs/getprop fetchdef "method"))
(println (vs/getprop fetchdef "headers"))
\`\`\`

### Use test mode

Create a mock client for unit testing — no server required:

\`\`\`clojure
(require '[sdk.api :as api]${testModeRequire}
         '[voxgig.struct :as vs])

(def client (api/test-sdk nil nil))

${testModeExample}
\`\`\`

### Use a custom fetch function

Replace the HTTP transport with your own function. A fetch fn takes the
URL and fetch definition and returns a \`[response err]\` pair; \`response\`
is a struct map carrying \`status\`, \`headers\`, and a \`json\` thunk:

\`\`\`clojure
(defn mock-fetch [url fetchdef]
  [(vs/jm "status" 200
          "statusText" "OK"
          "headers" (vs/jm)
          "json" (fn [] (vs/jm "id" "mock01")))
   nil])

(def client
  (api/make-sdk
    (vs/jm "base" "http://localhost:8080"
           "system" (vs/jm "fetch" mock-fetch))))
\`\`\`

### Run the test suite

The generated suite (pipeline, features, netsim, primary utility and the
vendored struct corpus) runs offline through a single \`tools.deps\` entry
point:

\`\`\`bash
cd ${target.name} && make test
\`\`\`

To exercise the SDK against the live API, construct a client with real
credentials and call its operations directly.

`)

})


export {
  ReadmeHowto
}
