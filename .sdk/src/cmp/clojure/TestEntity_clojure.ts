
import { cmp, Content } from '@voxgig/sdkgen'


// Emit per-entity model-driven checks INTO the shared gentest run body (the
// clojure test runner drives a single sdk.gentest/run). Covers: entity
// accessor existence, a create+list smoke run through the in-memory test-mode
// mock transport (exercising the full operation pipeline, hooks and run-op),
// and the streaming entity fn. API-agnostic behaviour (pipeline error
// branches, all features, netsim, primary utility, struct corpus) lives in the
// static template test namespaces.
const TestEntity = cmp(function TestEntity(props: any) {
  const e = props.entity

  const ops = Object.keys(e.op || {})
  const hasCreate = ops.includes('create')
  const hasList = ops.includes('list')

  // Accessor existence.
  Content(`  (t/run-check rec "gen-exists-${e.name}"
    (fn [] (let [sdk (api/test-sdk nil nil)]
             (t/is-true (some? (api/${e.name} sdk nil)) "${e.name} accessor present"))))
`)

  // create+list smoke run through the mock transport.
  if (hasCreate || hasList) {
    Content(`  (t/run-check rec "gen-smoke-${e.name}"
    (fn [] (let [sdk (api/test-sdk nil nil)
                 ent (api/${e.name} sdk nil)]
`)
    if (hasCreate) {
      Content(`             (let [res (e-${e.name}/create ent (vs/jm "name" "smoke") nil)
                   rec (if (map? res) ((:data-get res)) res)]
               ;; create resolves to the ENTITY; the record is data-get.
               (t/is-true (vs/ismap rec) "create resolves to an entity carrying a record")
               (t/is-true (some? (vs/getprop rec "id")) "created record has an id"))
`)
    }
    if (hasList) {
      Content(`             (let [items (e-${e.name}/list ent (vs/jm) nil)]
               ;; list resolves to one entity per record.
               (t/is-true (sequential? items) "list returns a sequential collection"))
`)
    }
    Content(`             )))
`)
  }

  // stream(action, args, callopts): runs the op through the full pipeline and
  // returns a lazy seq of items. Seeds three records via the test mock and
  // streams them; needs only a list op.
  if (hasList) {
    Content(`  (t/run-check rec "gen-stream-${e.name}"
    (fn [] (let [seed (vs/jm "${e.name}" (vs/jm "S1" (vs/jm "id" "S1" "name" "a")
                                                "S2" (vs/jm "id" "S2" "name" "b")
                                                "S3" (vs/jm "id" "S3" "name" "c")))]
             ;; Fallback (no streaming feature): materialised items.
             (let [sdk (api/test-sdk (vs/jm "entity" seed) nil)
                   items (vec (e-${e.name}/stream (api/${e.name} sdk nil) "list" (vs/jm) nil))]
               (t/is-eq (count items) 3 "stream fallback yields materialised items")
               (t/is-true (vs/ismap (first items)) "stream yields bare record maps"))
             ;; signal cancels iteration between yields.
             (let [sdk (api/test-sdk (vs/jm "entity" seed) nil)
                   n (atom 0) sig (fn [] (>= (swap! n inc) 2))
                   items (vec (e-${e.name}/stream (api/${e.name} sdk nil) "list" (vs/jm) (vs/jm "signal" sig)))]
               (t/is-eq (count items) 1 "stream signal stops after first yield"))
             ;; Streaming feature active: yields from the streaming iterator.
             (when (vs/getpath (config/make-config) "feature.streaming")
               (let [ssdk (api/test-sdk (vs/jm "entity" seed) (vs/jm "feature" (vs/jm "streaming" (vs/jm "active" true))))]
                 (t/is-eq (count (vec (e-${e.name}/stream (api/${e.name} ssdk nil) "list" (vs/jm) nil))) 3
                          "stream (streaming active) yields all items"))
               (let [csdk (api/test-sdk (vs/jm "entity" seed) (vs/jm "feature" (vs/jm "streaming" (vs/jm "active" true "chunkSize" 2))))
                     batches (vec (e-${e.name}/stream (api/${e.name} csdk nil) "list" (vs/jm) nil))]
                 (t/is-eq (count batches) 2 "stream chunkSize groups items into 2 batches"))))))
`)
  }
})


export {
  TestEntity
}
