
import { cmp, Content, invalidRequest, opReachable } from '@voxgig/sdkgen'


const TestEntity = cmp(function TestEntity(props: any) {
  const e = props.entity

  // Each smoke call passes only what it shows, so a bare call must reach a
  // route: a name for create, nothing for list.
  const hasCreate = opReachable(e.op?.create, ['name'])
  const hasList = opReachable(e.op?.list, [])

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

  if (hasList) {
    Content(`  (t/run-check rec "gen-list-${e.name}"
    (fn [] (let [seed (vs/jm "${e.name}" (vs/jm "L1" (vs/jm "id" "L1" "name" "a")
                                                "L2" (vs/jm "id" "L2" "name" "b")))
                 items (e-${e.name}/list (api/${e.name} (api/test-sdk (vs/jm "entity" seed) nil) nil)
                                         (vs/jm) nil)]
             ;; list resolves to one entity per record; data-get reads the record.
             (t/is-eq (count items) 2 "list answers each seeded record")
             (t/is-true (every? (fn [item] (and (map? item) (vs/ismap ((:data-get item))))) items)
                        "each listed item is an entity carrying its record"))))
  (t/run-check rec "gen-stream-${e.name}"
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

    // Failure paths: the stream, the caller's ctrl, and a throwing hook.
    Content(`  (t/run-check rec "gen-stream-error-${e.name}"
    (fn [] (let [offline (vs/jm "net" (vs/jm "offline" true))
                 err (try (vec (e-${e.name}/stream (api/${e.name} (api/test-sdk offline nil) nil) "list" (vs/jm) nil)) nil
                          (catch Throwable e e))]
             (t/is-true (and (some? err) (.contains (str (.getMessage ^Throwable err)) "offline"))
                        "the transport failure raises from the stream")
             (t/is-eq (count (vec (e-${e.name}/stream (api/${e.name} (api/test-sdk offline nil) nil) "list" (vs/jm)
                                                 (vs/jm "ctrl" (vs/jm "throw" false)))))
                      0 "throw false ends the stream quietly")
             (when (vs/getpath (config/make-config) "feature.rbac")
               (let [denied (api/test-sdk nil (vs/jm "feature" (vs/jm "rbac" (vs/jm "active" true "deny" true))))]
                 (t/is-throws (fn [] (vec (e-${e.name}/stream (api/${e.name} denied nil) "list" (vs/jm) nil)))
                              "rbac_denied" "the rbac denial raises from the stream"))))))
  (t/run-check rec "gen-stream-ctrl-${e.name}"
    (fn [] (let [explain (vs/jm)
                 ctrl (vs/jm "explain" explain)]
             (vec (e-${e.name}/stream (api/${e.name} (api/test-sdk nil nil) nil) "list" (vs/jm) (vs/jm "ctrl" ctrl)))
             (t/is-eq (vec (vs/keysof ctrl)) ["explain"] "the stream changed the caller's ctrl")
             (t/is-true (identical? explain (vs/getprop ctrl "explain")) "the caller's explain record is not its own")
             (t/is-true (pos? (count (vs/keysof explain))) "the caller's explain record was not filled"))))
  (t/run-check rec "gen-unexpected-${e.name}"
    (fn [] (let [seen (atom 0)
                 hook (atom {:name "failhook" :active true :version "0.0.1" :_options nil
                             "init" (fn [_ctx _opts] nil)
                             "PreSpec" (fn [_ctx] (throw (RuntimeException. "${e.name} hook failed")))
                             "PreUnexpected" (fn [_ctx] (swap! seen inc))})
                 ent (api/${e.name} (api/make-sdk (vs/jm "feature" (vs/jm "test" (vs/jm "active" true)) "extend" [hook])) nil)
                 err (try (e-${e.name}/list ent (vs/jm) nil) nil (catch Throwable e e))]
             (t/is-true (and (some? err) (.contains (str (.getMessage ^Throwable err)) "hook failed"))
                        "the hook's failure is raised")
             (t/is-true (pos? @seen) "PreUnexpected did not fire")
             (let [fired @seen]
               (t/is-nil (e-${e.name}/list ent (vs/jm) (vs/jm "throw" false)) "throw false should resolve to nothing")
               (t/is-true (> @seen fired) "PreUnexpected did not fire under throw false")))))
`)
  }

  const bad = invalidRequest(e)
  if (null != bad) {
    const args = Object.entries(bad.args)
      .map(([k, v]) => JSON.stringify(k) + ' ' + JSON.stringify(v)).join(' ')
    Content(`  (t/run-check rec "gen-validate-${e.name}"
    (fn [] (when (vs/getpath (config/make-config) "feature.validate")
             (let [client (api/test-sdk nil (vs/jm "feature" (vs/jm "validate" (vs/jm "active" true))))]
               (t/is-throws (fn [] (e-${e.name}/${bad.op} (api/${e.name} client nil) (vs/jm ${args}) nil))
                            "validate_failed" "validate refuses an invalid request")))))
`)
  }
})


export {
  TestEntity
}
