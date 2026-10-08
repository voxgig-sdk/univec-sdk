;; Univec SDK generated API tests.
(ns sdk.gentest
  (:require [sdk.api :as api]
            [sdk.config :as config]
            [sdk.testutil :as t]
            [clojure.string]
            [voxgig.struct :as vs]
            [sdk.entity.convert :as e-convert]
            [sdk.entity.embed :as e-embed]
            [sdk.entity.ephemeral_key :as e-ephemeral_key]
            [sdk.entity.model :as e-model]))

(defn run [rec]
  (t/run-check rec "gen-exists-convert"
    (fn [] (let [sdk (api/test-sdk nil nil)]
             (t/is-true (some? (api/convert sdk nil)) "convert accessor present"))))
  (t/run-check rec "gen-smoke-convert"
    (fn [] (let [sdk (api/test-sdk nil nil)
                 ent (api/convert sdk nil)]
             (let [res (e-convert/create ent (vs/jm "name" "smoke") nil)
                   rec (if (map? res) ((:data-get res)) res)]
               ;; create resolves to the ENTITY; the record is data-get.
               (t/is-true (vs/ismap rec) "create resolves to an entity carrying a record")
               (t/is-true (some? (vs/getprop rec "id")) "created record has an id"))
             )))
  (t/run-check rec "gen-validate-convert"
    (fn [] (when (vs/getpath (config/make-config) "feature.validate")
             (let [client (api/test-sdk nil (vs/jm "feature" (vs/jm "validate" (vs/jm "active" true))))]
               (t/is-throws (fn [] (e-convert/create (api/convert client nil) (vs/jm "embeddings" "x" "source_model" 1 "target_model" "x") nil))
                            "validate_failed" "validate refuses an invalid request")))))
  (t/run-check rec "gen-exists-embed"
    (fn [] (let [sdk (api/test-sdk nil nil)]
             (t/is-true (some? (api/embed sdk nil)) "embed accessor present"))))
  (t/run-check rec "gen-smoke-embed"
    (fn [] (let [sdk (api/test-sdk nil nil)
                 ent (api/embed sdk nil)]
             (let [res (e-embed/create ent (vs/jm "name" "smoke") nil)
                   rec (if (map? res) ((:data-get res)) res)]
               ;; create resolves to the ENTITY; the record is data-get.
               (t/is-true (vs/ismap rec) "create resolves to an entity carrying a record")
               (t/is-true (some? (vs/getprop rec "id")) "created record has an id"))
             )))
  (t/run-check rec "gen-validate-embed"
    (fn [] (when (vs/getpath (config/make-config) "feature.validate")
             (let [client (api/test-sdk nil (vs/jm "feature" (vs/jm "validate" (vs/jm "active" true))))]
               (t/is-throws (fn [] (e-embed/create (api/embed client nil) (vs/jm "embeddings" "x" "model" 1 "texts" "x") nil))
                            "validate_failed" "validate refuses an invalid request")))))
  (t/run-check rec "gen-exists-ephemeral_key"
    (fn [] (let [sdk (api/test-sdk nil nil)]
             (t/is-true (some? (api/ephemeral_key sdk nil)) "ephemeral_key accessor present"))))
  (t/run-check rec "gen-smoke-ephemeral_key"
    (fn [] (let [sdk (api/test-sdk nil nil)
                 ent (api/ephemeral_key sdk nil)]
             (let [res (e-ephemeral_key/create ent (vs/jm "name" "smoke") nil)
                   rec (if (map? res) ((:data-get res)) res)]
               ;; create resolves to the ENTITY; the record is data-get.
               (t/is-true (vs/ismap rec) "create resolves to an entity carrying a record")
               (t/is-true (some? (vs/getprop rec "id")) "created record has an id"))
             )))
  (t/run-check rec "gen-validate-ephemeral_key"
    (fn [] (when (vs/getpath (config/make-config) "feature.validate")
             (let [client (api/test-sdk nil (vs/jm "feature" (vs/jm "validate" (vs/jm "active" true))))]
               (t/is-throws (fn [] (e-ephemeral_key/create (api/ephemeral_key client nil) (vs/jm "dailyLimit" "x" "dailyUsed" 1 "key" "x" "resetsAt" "x") nil))
                            "validate_failed" "validate refuses an invalid request")))))
  (t/run-check rec "gen-exists-model"
    (fn [] (let [sdk (api/test-sdk nil nil)]
             (t/is-true (some? (api/model sdk nil)) "model accessor present"))))
  (t/run-check rec "gen-smoke-model"
    (fn [] (let [sdk (api/test-sdk nil nil)
                 ent (api/model sdk nil)]
             (let [items (e-model/list ent (vs/jm) nil)]
               ;; list resolves to one entity per record.
               (t/is-true (sequential? items) "list returns a sequential collection"))
             )))
  (t/run-check rec "gen-list-model"
    (fn [] (let [seed (vs/jm "model" (vs/jm "L1" (vs/jm "id" "L1" "name" "a")
                                                "L2" (vs/jm "id" "L2" "name" "b")))
                 items (e-model/list (api/model (api/test-sdk (vs/jm "entity" seed) nil) nil)
                                         (vs/jm) nil)]
             ;; list resolves to one entity per record; data-get reads the record.
             (t/is-eq (count items) 2 "list answers each seeded record")
             (t/is-true (every? (fn [item] (and (map? item) (vs/ismap ((:data-get item))))) items)
                        "each listed item is an entity carrying its record"))))
  (t/run-check rec "gen-stream-model"
    (fn [] (let [seed (vs/jm "model" (vs/jm "S1" (vs/jm "id" "S1" "name" "a")
                                                "S2" (vs/jm "id" "S2" "name" "b")
                                                "S3" (vs/jm "id" "S3" "name" "c")))]
             ;; Fallback (no streaming feature): materialised items.
             (let [sdk (api/test-sdk (vs/jm "entity" seed) nil)
                   items (vec (e-model/stream (api/model sdk nil) "list" (vs/jm) nil))]
               (t/is-eq (count items) 3 "stream fallback yields materialised items")
               (t/is-true (vs/ismap (first items)) "stream yields bare record maps"))
             ;; signal cancels iteration between yields.
             (let [sdk (api/test-sdk (vs/jm "entity" seed) nil)
                   n (atom 0) sig (fn [] (>= (swap! n inc) 2))
                   items (vec (e-model/stream (api/model sdk nil) "list" (vs/jm) (vs/jm "signal" sig)))]
               (t/is-eq (count items) 1 "stream signal stops after first yield"))
             ;; Streaming feature active: yields from the streaming iterator.
             (when (vs/getpath (config/make-config) "feature.streaming")
               (let [ssdk (api/test-sdk (vs/jm "entity" seed) (vs/jm "feature" (vs/jm "streaming" (vs/jm "active" true))))]
                 (t/is-eq (count (vec (e-model/stream (api/model ssdk nil) "list" (vs/jm) nil))) 3
                          "stream (streaming active) yields all items"))
               (let [csdk (api/test-sdk (vs/jm "entity" seed) (vs/jm "feature" (vs/jm "streaming" (vs/jm "active" true "chunkSize" 2))))
                     batches (vec (e-model/stream (api/model csdk nil) "list" (vs/jm) nil))]
                 (t/is-eq (count batches) 2 "stream chunkSize groups items into 2 batches"))))))
  (t/run-check rec "gen-stream-error-model"
    (fn [] (let [offline (vs/jm "net" (vs/jm "offline" true))
                 err (try (vec (e-model/stream (api/model (api/test-sdk offline nil) nil) "list" (vs/jm) nil)) nil
                          (catch Throwable e e))]
             (t/is-true (and (some? err) (.contains (str (.getMessage ^Throwable err)) "offline"))
                        "the transport failure raises from the stream")
             (t/is-eq (count (vec (e-model/stream (api/model (api/test-sdk offline nil) nil) "list" (vs/jm)
                                                 (vs/jm "ctrl" (vs/jm "throw" false)))))
                      0 "throw false ends the stream quietly")
             (when (vs/getpath (config/make-config) "feature.rbac")
               (let [denied (api/test-sdk nil (vs/jm "feature" (vs/jm "rbac" (vs/jm "active" true "deny" true))))]
                 (t/is-throws (fn [] (vec (e-model/stream (api/model denied nil) "list" (vs/jm) nil)))
                              "rbac_denied" "the rbac denial raises from the stream"))))))
  (t/run-check rec "gen-stream-ctrl-model"
    (fn [] (let [explain (vs/jm)
                 ctrl (vs/jm "explain" explain)]
             (vec (e-model/stream (api/model (api/test-sdk nil nil) nil) "list" (vs/jm) (vs/jm "ctrl" ctrl)))
             (t/is-eq (vec (vs/keysof ctrl)) ["explain"] "the stream changed the caller's ctrl")
             (t/is-true (identical? explain (vs/getprop ctrl "explain")) "the caller's explain record is not its own")
             (t/is-true (pos? (count (vs/keysof explain))) "the caller's explain record was not filled"))))
  (t/run-check rec "gen-unexpected-model"
    (fn [] (let [seen (atom 0)
                 hook (atom {:name "failhook" :active true :version "0.0.1" :_options nil
                             "init" (fn [_ctx _opts] nil)
                             "PreSpec" (fn [_ctx] (throw (RuntimeException. "model hook failed")))
                             "PreUnexpected" (fn [_ctx] (swap! seen inc))})
                 ent (api/model (api/make-sdk (vs/jm "feature" (vs/jm "test" (vs/jm "active" true)) "extend" [hook])) nil)
                 err (try (e-model/list ent (vs/jm) nil) nil (catch Throwable e e))]
             (t/is-true (and (some? err) (.contains (str (.getMessage ^Throwable err)) "hook failed"))
                        "the hook's failure is raised")
             (t/is-true (pos? @seen) "PreUnexpected did not fire")
             (let [fired @seen]
               (t/is-nil (e-model/list ent (vs/jm) (vs/jm "throw" false)) "throw false should resolve to nothing")
               (t/is-true (> @seen fired) "PreUnexpected did not fire under throw false")))))
  (t/run-check rec "gen-validate-model"
    (fn [] (when (vs/getpath (config/make-config) "feature.validate")
             (let [client (api/test-sdk nil (vs/jm "feature" (vs/jm "validate" (vs/jm "active" true))))]
               (t/is-throws (fn [] (e-model/list (api/model client nil) (vs/jm "executionProvider" 1) nil))
                            "validate_failed" "validate refuses an invalid request")))))
  (t/run-check rec "gen-prepare-model"
    (fn [] (let [client (api/make-sdk (vs/jm "base" "http://example.test" "apikey" "test-key"))
                 fetchdef (api/prepare client (vs/jm "path" "/api/model" "method" "GET"))]
             (t/is-true (vs/ismap fetchdef) "prepare returns a fetchdef map")
             (t/is-some (vs/getprop fetchdef "url") "fetchdef carries a url")
             (t/is-eq (vs/getprop fetchdef "method") "GET" "fetchdef preserves the method"))))
  (t/run-check rec "gen-direct-model"
    (fn [] (let [fetch (fn [_url _fetchdef]
                         [(vs/jm "status" 200 "statusText" "OK" "headers" (vs/jm)
                                 "json" (fn [] (vs/jm "id" "d1"))) nil])
                 client (api/make-sdk (vs/jm "base" "http://example.test" "apikey" "test-key"
                                             "system" (vs/jm "fetch" fetch)))
                 result (api/direct client (vs/jm "path" "/api/model" "method" "GET"))]
             (t/is-true (vs/ismap result) "direct returns a result map")
             (t/is-true (vs/getprop result "ok") "direct 200 => ok true")
             (t/is-eq (vs/getprop result "status") 200 "direct surfaces the status"))))
  (letfn [(fence-pat [] (re-pattern (apply str (repeat 3 (char 96)))))
          (fence-count [text] (count (re-seq (fence-pat) text)))
          (clj-blocks [text]
            (let [parts (clojure.string/split text (fence-pat))]
              (->> parts
                   (map-indexed vector)
                   (filter (fn [[i _]] (odd? i)))
                   (map (fn [[_ seg]] seg))
                   (filter (fn [seg]
                             (= "clojure"
                                (clojure.string/trim (first (clojure.string/split-lines seg))))))
                   (map (fn [seg]
                          (clojure.string/join "\n"
                            (rest (clojure.string/split-lines seg))))))))]
    (doseq [[label path] [["root-README" "../README.md"]
                          ["README" "README.md"]
                          ["REFERENCE" "REFERENCE.md"]]]
      (t/run-check rec (str "gen-readme-examples-" label)
        (fn []
          (if-not (.exists (java.io.File. ^String path))
            (t/is-true true (str label " absent (skipped)"))
            (let [text (slurp path)]
              ;; A code fence opened but never closed leaves an ODD number of
              ;; fence markers; the split-on-fence then captures the trailing
              ;; prose (everything after the last opener) as if it were a
              ;; clojure block, which can parse cleanly and pass silently. Fail
              ;; on the malformed doc instead. (Count markers directly rather
              ;; than split parts: split drops trailing empty segments, so a
              ;; closing fence at EOF would be miscounted.)
              (t/is-true (even? (fence-count text))
                         (str label " code fences balanced (no unclosed fence)"))
              (let [blocks (clj-blocks text)]
                (doseq [b blocks]
                  (binding [*read-eval* false]
                    (read-string (str "[\n" b "\n]"))))
                (t/is-true true (str label " clojure blocks parse cleanly")))))))))
  nil)
