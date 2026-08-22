;; Univec SDK feature behaviour tests.
;;
;; Drives each shipped feature through an offline miniature of the operation
;; pipeline (same hook order + short-circuit rules as the generated entity
;; ops) against a configurable mock transport. Timing uses an injectable
;; virtual clock, so the suite is deterministic.
(ns sdk.test.feature
  (:require [sdk.core :as core]
            [sdk.features :as features]
            [sdk.config :as config]
            [sdk.testutil :as t]
            [voxgig.struct :as vs]
            [clojure.string :as str]))

(defn- mget [m k] (when (instance? java.util.Map m) (.get ^java.util.Map m k)))

(defn feature-present? [name]
  (let [f (vs/getprop (config/make-config) "feature")]
    (and (vs/ismap f) (some? (vs/getprop f name)))))

(defn fspec [name & kvs] {"name" name "options" (if (seq kvs) (apply vs/jm kvs) (vs/jm))})

(defn default-method [opname]
  (cond (= opname "create") "POST" (= opname "update") "PATCH" (= opname "remove") "DELETE" :else "GET"))

(defn make-response [status data headers]
  (let [h (vs/jm)]
    (when (vs/ismap headers) (doseq [item (or (vs/items headers) [])]
                               (.put ^java.util.Map h (str/lower-case (str (vs/getprop item 0))) (vs/getprop item 1))))
    (vs/jm "status" status "statusText" (if (< status 400) "OK" "ERR") "body" "not-used"
           "json" (fn [] data) "headers" h)))

(defn default-server []
  (fn [_fctx _url fetchdef]
    (let [method (str/upper-case (str (or (vs/getprop fetchdef "method") "GET")))]
      (if (= method "GET")
        [(make-response 200 (vs/jm "ok" true "method" method) nil) nil]
        [(make-response 200 (vs/jm "ok" true "method" method "echo" (vs/getprop fetchdef "body")) nil) nil]))))

(defn recording-server [reply]
  (let [calls (atom [])
        server (fn [_fctx url fetchdef]
                 (swap! calls conj (vs/jm "url" url "fetchdef" fetchdef))
                 (if reply (reply (count @calls) fetchdef)
                     [(make-response 200 (vs/jm "ok" true "n" (count @calls)) nil) nil]))]
    [server calls]))

;; Virtual clock.
(defn make-clock [] (atom 0))
(defn clock-now [c] (fn [] @c))
(defn clock-sleeper [c] (fn [ms] (swap! c + (or ms 0))))
(defn clock-advance [c ms] (swap! c + ms))

(defn fake-entity [name] {:get-name (fn [] name)})

(defn- merge-headers [base extra]
  (let [out (if (vs/ismap base) (vs/clone base) (vs/jm))]
    (when (vs/ismap extra) (doseq [item (or (vs/items extra) [])]
                             (.put ^java.util.Map out (vs/getprop item 0) (vs/getprop item 1))))
    out))

(defn- build-url [spec]
  (let [q (or (core/oget spec :query) (vs/jm))
        ks (sort (filter (fn [k] (some? (vs/getprop q k))) (or (vs/keysof q) [])))
        qs (str/join "&" (map (fn [k] (str (vs/escurl (str k)) "=" (vs/escurl (str (vs/getprop q k))))) ks))]
    (str (core/oget spec :base) (core/oget spec :path) (if (empty? qs) "" (str "?" qs)))))

(defn- populate-result [ctx fetched fetch-err]
  (let [result (core/make-result (vs/jm))]
    (core/oset! ctx :result result)
    (cond
      fetch-err (core/oset! result :err fetch-err)
      (nil? fetched) (core/oset! result :err (core/ctx-error ctx "op_no_response" "response: undefined"))
      :else
      (let [response (core/oget ctx :response)
            headers (vs/jm)]
        (core/oset! result :status (core/oget response :status))
        (core/oset! result :status-text (core/oget response :status-text))
        (when (vs/ismap (core/oget response :headers))
          (doseq [item (or (vs/items (core/oget response :headers)) [])]
            (.put ^java.util.Map headers (str/lower-case (str (vs/getprop item 0))) (vs/getprop item 1))))
        (core/oset! result :headers headers)
        (when (core/oget response :json) (core/oset! result :body ((core/oget response :json))))
        (core/oset! result :resdata (core/oget result :body))
        (when (>= (core/oget result :status) 400)
          (core/oset! result :err (core/ctx-error ctx "request_status"
                                                  (str "request: " (core/oget result :status) ": " (core/oget result :status-text)))))
        (when (nil? (core/oget result :err)) (core/oset! result :ok true))))))

(defn make-harness [feature-specs & {:keys [server base headers] :or {base "http://api.test"}}]
  (let [headers (or headers (vs/jm))
        utility (core/make-utility)
        _ (core/oset! utility :fetcher (or server (default-server)))
        client {:features (atom []) :mode (atom "test") :store (atom {})
                :options (atom (vs/jm "base" base "headers" headers "feature" (vs/jm)))}
        rootctx (core/make-context (vs/jm "client" client "utility" utility "options" (deref (:options client))) nil)]
    (doseq [fs feature-specs]
      (let [name (get fs "name")]
        (when (feature-present? name)
          (let [f (features/make-feature name)
                fopts (let [o (vs/jm "active" true)]
                        (doseq [item (or (vs/items (or (get fs "options") (vs/jm))) [])]
                          (.put ^java.util.Map o (vs/getprop item 0) (vs/getprop item 1)))
                        o)]
            (.put ^java.util.Map (vs/getprop (deref (:options client)) "feature") name fopts)
            ((get (deref f) "init") rootctx fopts)
            (swap! (:features client) conj f)))))
    {:client client :utility utility :rootctx rootctx :base base :headers headers :booted (atom false)}))

(defn h-ready [h] (when-not @(:booted h) (reset! (:booted h) true) (core/feature-hook (:rootctx h) "PostConstruct")))
(defn h-track [h k] (core/client-track (:client h) k))
(defn h-feature [h name] (first (filter (fn [f] (= (core/feature-get-name f) name)) @(:features (:client h)))))

(defn h-op [h & {:keys [opname entity method path query headers body ctrl]
                 :or {opname "load" entity "widget"}}]
  (let [utility (:utility h) rootctx (:rootctx h)
        method (or method (default-method opname))
        ctx (core/make-context (vs/jm "opname" opname "entity" (fake-entity entity) "ctrl" (or ctrl (vs/jm))) rootctx)]
    (core/feature-hook ctx "PostConstructEntity")
    (try
      (core/feature-hook ctx "PrePoint")
      (when (core/sdk-error? (core/out-get ctx "point")) (core/sdk-throw (core/out-get ctx "point")))
      (core/feature-hook ctx "PreSpec")
      (let [spec (core/make-spec (vs/jm "method" method "base" (:base h) "path" (or path (str "/" entity))
                                        "params" (vs/jm) "headers" (merge-headers (:headers h) headers)
                                        "query" (or query (vs/jm)) "body" body "step" "start"))]
        (core/oset! ctx :spec spec)
        (core/feature-hook ctx "PreRequest")
        (let [url (build-url spec)]
          (core/oset! spec :url url)
          (let [fetchdef (vs/jm "url" url "method" (core/oget spec :method)
                                "headers" (core/oget spec :headers) "body" (core/oget spec :body))
                [fetched fetch-err] ((core/uget ctx :fetcher) ctx url fetchdef)]
            (core/oset! ctx :response (when (vs/ismap fetched) (core/make-response fetched)))
            (core/feature-hook ctx "PreResponse")
            (populate-result ctx fetched fetch-err)
            (core/feature-hook ctx "PreResult")
            (core/feature-hook ctx "PreDone")
            (let [result (core/oget ctx :result)]
              (if (and result (core/oget result :ok))
                {"ok" true "data" (core/oget result :resdata) "result" result "ctx" ctx}
                (core/sdk-throw (or (and result (core/oget result :err))
                                    (core/ctx-error ctx "op_failed" "operation failed"))))))))
      (catch clojure.lang.ExceptionInfo e
        (let [err (core/ex->sdk e)]
          (core/oset! (core/oget ctx :ctrl) :err err)
          (core/feature-hook ctx "PreUnexpected")
          {"ok" false "error" err "result" (core/oget ctx :result) "ctx" ctx})))))

(defn- rstatus [res] (core/oget (get res "result") :status))
(defn- rcode [res] (:code (get res "error")))

;; ---------------------------------------------------------------------------
;; The suite.
;; ---------------------------------------------------------------------------

(defn run [rec]
  (letfn [(check [name skip-feat thunk]
            (t/run-check rec name
                         (fn [] (if (and skip-feat (not (feature-present? skip-feat)))
                                  true (thunk)))))]

    (check "feature-test-present" nil (fn [] (t/is-true (feature-present? "test") "test feature present")))

    ;; ---- netsim ----
    (check "netsim-fixed-latency-then-delegate" "netsim"
           (fn [] (let [c (make-clock)
                        h (make-harness [(fspec "netsim" "latency" 250 "sleep" (clock-sleeper c))])
                        res (h-op h :ctrl (vs/jm "explain" (vs/jm)))]
                    (t/is-eq (get res "ok") true "ok")
                    (t/is-eq @c 250 "latency")
                    (t/is-eq (mget (h-track h "_netsim") "calls") 1 "calls"))))
    (check "netsim-ranged-latency-in-range" "netsim"
           (fn [] (let [c (make-clock)
                        h (make-harness [(fspec "netsim" "latency" (vs/jm "min" 100 "max" 300) "seed" 7 "sleep" (clock-sleeper c))])]
                    (h-op h) (t/is-true (and (>= @c 100) (< @c 300)) "in range"))))
    (check "netsim-equal-min-max-exact" "netsim"
           (fn [] (let [c (make-clock)
                        h (make-harness [(fspec "netsim" "latency" (vs/jm "min" 50 "max" 50) "sleep" (clock-sleeper c))])]
                    (h-op h) (t/is-eq @c 50 "exact"))))
    (check "netsim-fail-times-retryable-status" "netsim"
           (fn [] (let [h (make-harness [(fspec "netsim" "failTimes" 2 "failStatus" 503)])]
                    (t/is-eq (rstatus (h-op h)) 503 "first")
                    (t/is-eq (rstatus (h-op h)) 503 "second")
                    (t/is-eq (get (h-op h) "ok") true "third"))))
    (check "netsim-fail-every-nth" "netsim"
           (fn [] (let [h (make-harness [(fspec "netsim" "failEvery" 2)])]
                    (t/is-eq (get (h-op h) "ok") true "1")
                    (t/is-eq (get (h-op h) "ok") false "2")
                    (t/is-eq (get (h-op h) "ok") true "3"))))
    (check "netsim-fail-rate-seed-deterministic" "netsim"
           (fn [] (let [h (make-harness [(fspec "netsim" "failRate" 1 "seed" 5)])]
                    (t/is-eq (get (h-op h) "ok") false "fail"))))
    (check "netsim-error-times-conn-error" "netsim"
           (fn [] (let [h (make-harness [(fspec "netsim" "errorTimes" 1)])]
                    (t/is-eq (rcode (h-op h)) "netsim_conn" "conn"))))
    (check "netsim-offline" "netsim"
           (fn [] (let [h (make-harness [(fspec "netsim" "offline" true)])]
                    (t/is-eq (rcode (h-op h)) "netsim_offline" "offline"))))
    (check "netsim-rate-limit-429-retry-after" "netsim"
           (fn [] (let [h (make-harness [(fspec "netsim" "rateLimitTimes" 1 "retryAfter" 3)])
                        res (h-op h)]
                    (t/is-eq (rstatus res) 429 "429")
                    (t/is-eq (mget (core/oget (get res "result") :headers) "retry-after") "3" "retry-after"))))
    (check "netsim-inactive-does-not-wrap" "netsim"
           (fn [] (let [h (make-harness [(fspec "netsim" "active" false)])]
                    (t/is-eq (get (h-op h) "ok") true "ok")
                    (t/is-nil (h-track h "_netsim") "no track"))))

    ;; ---- retry ----
    (check "retry-retries-then-succeeds" "retry"
           (fn [] (when (feature-present? "netsim")
                    (let [c (make-clock)
                          h (make-harness [(fspec "netsim" "failTimes" 2 "failStatus" 503)
                                           (fspec "retry" "retries" 3 "minDelay" 10 "jitter" false "sleep" (clock-sleeper c))])]
                      (t/is-eq (get (h-op h) "ok") true "ok")
                      (t/is-eq (mget (h-track h "_retry") "attempts") 2 "attempts")))))
    (check "retry-gives-up-after-budget" "retry"
           (fn [] (when (feature-present? "netsim")
                    (let [c (make-clock)
                          h (make-harness [(fspec "netsim" "failTimes" 9 "failStatus" 500)
                                           (fspec "retry" "retries" 2 "minDelay" 1 "jitter" false "sleep" (clock-sleeper c))])]
                      (t/is-eq (rstatus (h-op h)) 500 "500")))))
    (check "retry-no-retry-non-retryable" "retry"
           (fn [] (let [[server calls] (recording-server (fn [_n _fd] [(make-response 404 nil nil) nil]))
                        h (make-harness [(fspec "retry" "retries" 3 "minDelay" 0 "jitter" false)] :server server)]
                    (h-op h) (t/is-eq (count @calls) 1 "one call"))))
    (check "retry-retries-transport-error" "retry"
           (fn [] (let [c (make-clock)
                        [server calls] (recording-server (fn [n _fd] (if (< n 3) [nil (core/make-error-obj "boom" "boom")]
                                                                          [(make-response 200 (vs/jm "ok" true) nil) nil])))
                        h (make-harness [(fspec "retry" "retries" 2 "minDelay" 1 "jitter" false "sleep" (clock-sleeper c))] :server server)
                        res (h-op h)]
                    (t/is-eq (get res "ok") true "ok")
                    (t/is-eq (count @calls) 3 "3 calls"))))
    (check "retry-exhausted-transport-error" "retry"
           (fn [] (let [c (make-clock)
                        [server calls] (recording-server (fn [_n _fd] [nil (core/make-error-obj "boom" "boom")]))
                        h (make-harness [(fspec "retry" "retries" 2 "minDelay" 1 "jitter" false "sleep" (clock-sleeper c))] :server server)
                        res (h-op h)]
                    (t/is-eq (get res "ok") false "not ok")
                    (t/is-eq (count @calls) 3 "3 calls"))))
    (check "retry-honours-retry-after" "retry"
           (fn [] (when (feature-present? "netsim")
                    (let [c (make-clock)
                          h (make-harness [(fspec "netsim" "rateLimitTimes" 1 "retryAfter" 2)
                                           (fspec "retry" "retries" 2 "minDelay" 10 "maxDelay" 60000 "jitter" false "sleep" (clock-sleeper c))])]
                      (t/is-eq (get (h-op h) "ok") true "ok")
                      (t/is-eq @c 2000 "waited 2000")))))
    (check "retry-inactive-does-not-wrap" "retry"
           (fn [] (let [[server calls] (recording-server (fn [_n _fd] [(make-response 503 nil nil) nil]))
                        h (make-harness [(fspec "retry" "active" false)] :server server)]
                    (h-op h) (t/is-eq (count @calls) 1 "one call"))))

    ;; ---- timeout ----
    (check "timeout-expires-slow-request" "timeout"
           (fn [] (let [c (make-clock)
                        sleeper (clock-sleeper c)
                        server (fn [_fctx _u _fd] (sleeper 80) [(make-response 200 (vs/jm "ok" true) nil) nil])
                        h (make-harness [(fspec "timeout" "ms" 10 "now" (clock-now c))] :server server)
                        res (h-op h)]
                    (t/is-eq (rcode res) "timeout" "timeout")
                    (t/is-eq (mget (h-track h "_timeout") "count") 1 "count"))))
    (check "timeout-fast-passes" "timeout"
           (fn [] (let [c (make-clock)
                        h (make-harness [(fspec "timeout" "ms" 1000 "now" (clock-now c))])]
                    (t/is-eq (get (h-op h) "ok") true "ok"))))
    (check "timeout-ms-zero-disables" "timeout"
           (fn [] (let [h (make-harness [(fspec "timeout" "ms" 0)])]
                    (t/is-eq (get (h-op h) "ok") true "ok"))))
    (check "timeout-interrupts-hanging" "timeout"
           (fn [] (let [server (fn [_fctx _u _fd] (Thread/sleep 50) [(make-response 200 (vs/jm "ok" true) nil) nil])
                        h (make-harness [(fspec "timeout" "ms" 10)] :server server)]
                    (t/is-eq (rcode (h-op h)) "timeout" "timeout"))))
    (check "timeout-inactive-does-not-wrap" "timeout"
           (fn [] (let [h (make-harness [(fspec "timeout" "active" false)])]
                    (t/is-eq (get (h-op h) "ok") true "ok"))))

    ;; ---- ratelimit ----
    (check "ratelimit-throttles-after-burst" "ratelimit"
           (fn [] (let [c (make-clock)
                        h (make-harness [(fspec "ratelimit" "rate" 1 "burst" 2 "now" (clock-now c) "sleep" (clock-sleeper c))])]
                    (h-op h) (h-op h) (h-op h)
                    (t/is-eq (mget (h-track h "_ratelimit") "throttled") 1 "throttled")
                    (t/is-true (> @c 0) "time advanced"))))
    (check "ratelimit-burst-defaults-and-refills" "ratelimit"
           (fn [] (let [c (make-clock)
                        h (make-harness [(fspec "ratelimit" "rate" 2 "now" (clock-now c) "sleep" (clock-sleeper c))])]
                    (h-op h) (h-op h) (clock-advance c 1000) (h-op h)
                    (let [track (h-track h "_ratelimit")]
                      (t/is-eq (if track (mget track "throttled") 0) 0 "no throttle")))))
    (check "ratelimit-inactive-does-not-wrap" "ratelimit"
           (fn [] (let [h (make-harness [(fspec "ratelimit" "active" false)])]
                    (t/is-eq (get (h-op h) "ok") true "ok")
                    (t/is-nil (h-track h "_ratelimit") "no track"))))

    ;; ---- cache ----
    (check "cache-serves-repeated-read" "cache"
           (fn [] (let [[server calls] (recording-server nil)
                        h (make-harness [(fspec "cache" "ttl" 10000)] :server server)
                        a (h-op h :path "/w/1") b (h-op h :path "/w/1")]
                    (t/is-eq (count @calls) 1 "one call")
                    (t/is-deep (get a "data") (get b "data") "same data")
                    (t/is-eq (mget (h-track h "_cache") "hit") 1 "hit"))))
    (check "cache-does-not-cache-non-get" "cache"
           (fn [] (let [[server calls] (recording-server nil)
                        h (make-harness [(fspec "cache")] :server server)]
                    (h-op h :opname "create" :path "/w") (h-op h :opname "create" :path "/w")
                    (t/is-eq (count @calls) 2 "two calls"))))
    (check "cache-does-not-cache-non-2xx" "cache"
           (fn [] (let [[server calls] (recording-server (fn [_n _fd] [(make-response 500 nil nil) nil]))
                        h (make-harness [(fspec "cache")] :server server)]
                    (h-op h :path "/w") (h-op h :path "/w")
                    (t/is-eq (count @calls) 2 "two calls")
                    (t/is-eq (mget (h-track h "_cache") "bypass") 2 "bypass"))))
    (check "cache-refetches-after-ttl" "cache"
           (fn [] (let [c (make-clock)
                        [server calls] (recording-server nil)
                        h (make-harness [(fspec "cache" "ttl" 1000 "now" (clock-now c))] :server server)]
                    (h-op h :path "/w") (clock-advance c 1500) (h-op h :path "/w")
                    (t/is-eq (count @calls) 2 "two calls"))))
    (check "cache-evicts-oldest-past-max" "cache"
           (fn [] (let [[server calls] (recording-server nil)
                        h (make-harness [(fspec "cache" "ttl" 10000 "max" 1)] :server server)]
                    (h-op h :path "/a") (h-op h :path "/b") (h-op h :path "/a")
                    (t/is-eq (count @calls) 3 "three calls"))))
    (check "cache-inactive-does-not-wrap" "cache"
           (fn [] (let [[server calls] (recording-server nil)
                        h (make-harness [(fspec "cache" "active" false)] :server server)]
                    (h-op h :path "/x") (h-op h :path "/x")
                    (t/is-eq (count @calls) 2 "two calls"))))

    ;; ---- idempotency ----
    (check "idempotency-adds-key-mutating" "idempotency"
           (fn [] (let [[server calls] (recording-server nil)
                        h (make-harness [(fspec "idempotency")] :server server)]
                    (h-op h :opname "create" :path "/w")
                    (t/is-some (mget (vs/getprop (nth @calls 0) "fetchdef") "headers") "headers")
                    (t/is-some (mget (vs/getprop (vs/getprop (nth @calls 0) "fetchdef") "headers") "Idempotency-Key") "key")
                    (t/is-eq (mget (h-track h "_idempotency") "issued") 1 "issued"))))
    (check "idempotency-by-http-method" "idempotency"
           (fn [] (let [[server calls] (recording-server nil)
                        h (make-harness [(fspec "idempotency")] :server server)]
                    (h-op h :opname "act" :method "PUT" :path "/w")
                    (t/is-some (mget (vs/getprop (vs/getprop (nth @calls 0) "fetchdef") "headers") "Idempotency-Key") "key"))))
    (check "idempotency-leaves-reads" "idempotency"
           (fn [] (let [[server calls] (recording-server nil)
                        h (make-harness [(fspec "idempotency")] :server server)]
                    (h-op h :path "/w/1")
                    (t/is-nil (mget (vs/getprop (vs/getprop (nth @calls 0) "fetchdef") "headers") "Idempotency-Key") "no key"))))
    (check "idempotency-preserves-caller-key" "idempotency"
           (fn [] (let [[server calls] (recording-server nil)
                        h (make-harness [(fspec "idempotency" "header" "X-Idem")] :server server)]
                    (h-op h :opname "create" :path "/w" :headers (vs/jm "X-Idem" "caller-1"))
                    (t/is-eq (mget (vs/getprop (vs/getprop (nth @calls 0) "fetchdef") "headers") "X-Idem") "caller-1" "caller key"))))
    (check "idempotency-injected-keygen" "idempotency"
           (fn [] (let [[server calls] (recording-server nil)
                        h (make-harness [(fspec "idempotency" "keygen" (fn [] "K1"))] :server server)]
                    (h-op h :opname "create" :path "/w")
                    (t/is-eq (mget (vs/getprop (vs/getprop (nth @calls 0) "fetchdef") "headers") "Idempotency-Key") "K1" "K1"))))

    ;; ---- rbac (short-circuit, gotcha #2) ----
    (check "rbac-denies-before-network" "rbac"
           (fn [] (let [[server calls] (recording-server nil)
                        h (make-harness [(fspec "rbac" "rules" (vs/jm "widget.remove" "admin") "permissions" (vs/jt))] :server server)
                        res (h-op h :opname "remove" :path "/w/1")]
                    (t/is-eq (rcode res) "rbac_denied" "denied")
                    (t/is-eq (count @calls) 0 "no network")
                    (t/is-eq (mget (h-track h "_rbac") "denied") 1 "denied count"))))
    (check "rbac-allows-held-permission" "rbac"
           (fn [] (let [h (make-harness [(fspec "rbac" "rules" (vs/jm "widget.remove" "admin") "permissions" (vs/jt "admin"))])]
                    (t/is-eq (get (h-op h :opname "remove" :path "/w/1") "ok") true "ok")
                    (t/is-eq (mget (h-track h "_rbac") "allowed") 1 "allowed"))))
    (check "rbac-rule-by-op-and-wildcard" "rbac"
           (fn [] (let [h (make-harness [(fspec "rbac" "rules" (vs/jm "load" "read") "permissions" (vs/jt "*"))])]
                    (t/is-eq (get (h-op h) "ok") true "ok"))))
    (check "rbac-no-rule-default-and-deny" "rbac"
           (fn [] (let [allow (make-harness [(fspec "rbac" "permissions" (vs/jt))])]
                    (t/is-eq (get (h-op allow) "ok") true "allow")
                    (let [deny (make-harness [(fspec "rbac" "deny" true "permissions" (vs/jt))])]
                      (t/is-eq (rcode (h-op deny)) "rbac_denied" "deny")))))

    ;; ---- metrics ----
    (check "metrics-counts-ok-err" "metrics"
           (fn [] (when (feature-present? "netsim")
                    (let [h (make-harness [(fspec "netsim" "failTimes" 1 "failStatus" 500) (fspec "metrics")])]
                      (h-op h) (h-op h) (h-op h :opname "list")
                      (let [m (h-track h "_metrics")]
                        (t/is-eq (mget (mget m "total") "count") 3 "count")
                        (t/is-eq (mget (mget m "total") "ok") 2 "ok")
                        (t/is-eq (mget (mget m "total") "err") 1 "err")
                        (t/is-eq (mget (mget (mget m "ops") "widget.load") "count") 2 "load count"))))))
    (check "metrics-injected-clock" "metrics"
           (fn [] (let [t (atom 0)
                        h (make-harness [(fspec "metrics" "now" (fn [] (swap! t + 10)))])]
                    (h-op h)
                    (let [m (h-track h "_metrics")]
                      (t/is-eq (mget (mget m "total") "count") 1 "count")
                      (t/is-eq (mget (mget m "total") "totalMs") 10 "totalMs")
                      (t/is-eq (mget (mget m "total") "maxMs") 10 "maxMs")))))

    ;; ---- telemetry ----
    (check "telemetry-spans-and-headers" "telemetry"
           (fn [] (let [[server calls] (recording-server nil)
                        spans (atom [])
                        h (make-harness [(fspec "telemetry" "exporter" (fn [s] (swap! spans conj s)))] :server server)
                        res (h-op h)]
                    (t/is-eq (get res "ok") true "ok")
                    (let [tel (h-track h "_telemetry")]
                      (t/is-eq (vs/size (mget tel "spans")) 1 "1 span")
                      (t/is-eq (count @spans) 1 "1 exported")
                      (let [sent (mget (vs/getprop (nth @calls 0) "fetchdef") "headers")]
                        (t/is-eq (mget sent "X-Trace-Id") (mget (vs/getelem (mget tel "spans") 0) "traceId") "trace id")
                        (t/is-true (boolean (re-matches #"00-.+-.+-01" (str (mget sent "traceparent")))) "traceparent"))))))
    (check "telemetry-failed-span" "telemetry"
           (fn [] (when (feature-present? "netsim")
                    (let [h (make-harness [(fspec "netsim" "failTimes" 1 "failStatus" 500) (fspec "telemetry")])]
                      (h-op h)
                      (let [tel (h-track h "_telemetry")]
                        (t/is-eq (mget (vs/getelem (mget tel "spans") 0) "ok") false "failed")
                        (t/is-eq (mget tel "active") 0 "active 0"))))))
    (check "telemetry-injected-idgen-clock" "telemetry"
           (fn [] (let [h (make-harness [(fspec "telemetry" "idgen" (fn [k] (str k "-X")) "now" (fn [] 5))])]
                    (h-op h)
                    (let [span (vs/getelem (mget (h-track h "_telemetry") "spans") 0)]
                      (t/is-eq (mget span "traceId") "trace-X" "traceId")
                      (t/is-eq (mget span "durationMs") 0 "duration 0")))))

    ;; ---- debug ----
    (check "debug-redacted-trace-on-entry-max" "debug"
           (fn [] (let [seen (atom [])
                        h (make-harness [(fspec "debug" "max" 1 "on_entry" (fn [e] (swap! seen conj e)))])]
                    (h-op h :headers (vs/jm "authorization" "Bearer secret"))
                    (h-op h :opname "list")
                    (let [entries (mget (h-track h "_debug") "entries")]
                      (t/is-eq (vs/size entries) 1 "capped")
                      (t/is-eq (count @seen) 2 "2 seen")
                      (t/is-eq (mget (mget (nth @seen 0) "headers") "authorization") "<redacted>" "redacted")))))
    (check "debug-captures-failures" "debug"
           (fn [] (when (feature-present? "netsim")
                    (let [h (make-harness [(fspec "netsim" "failTimes" 1 "failStatus" 500) (fspec "debug")])]
                      (h-op h)
                      (let [entry (vs/getelem (mget (h-track h "_debug") "entries") 0)]
                        (t/is-eq (mget entry "ok") false "not ok")
                        (t/is-eq (mget entry "status") 500 "500"))))))
    (check "debug-injected-clock-custom-redact" "debug"
           (fn [] (let [h (make-harness [(fspec "debug" "now" (fn [] 7) "redact" (vs/jt "x-secret"))])]
                    (h-op h :headers (vs/jm "x-secret" "hide" "x-ok" "show"))
                    (let [entry (vs/getelem (mget (h-track h "_debug") "entries") 0)]
                      (t/is-eq (mget (mget entry "headers") "x-secret") "<redacted>" "redacted")
                      (t/is-eq (mget (mget entry "headers") "x-ok") "show" "shown")))))

    ;; ---- audit ----
    (check "audit-one-record-per-op" "audit"
           (fn [] (when (feature-present? "netsim")
                    (let [sink (atom [])
                          h (make-harness [(fspec "netsim" "failTimes" 1 "failStatus" 500)
                                           (fspec "audit" "actor" "svc" "sink" (fn [r] (swap! sink conj r)) "max" 5)])]
                      (h-op h :opname "remove" :path "/w/1")
                      (h-op h :ctrl (vs/jm "actor" "per-call"))
                      (let [recs (mget (h-track h "_audit") "records")]
                        (t/is-eq (vs/size recs) 2 "2 recs")
                        (t/is-eq (mget (vs/getelem recs 0) "outcome") "error" "error")
                        (t/is-eq (mget (vs/getelem recs 0) "actor") "svc" "svc")
                        (t/is-eq (mget (vs/getelem recs 1) "actor") "per-call" "per-call")
                        (t/is-eq (mget (vs/getelem recs 1) "outcome") "ok" "ok")
                        (t/is-eq (count @sink) 2 "sink 2"))))))
    (check "audit-default-actor-clock" "audit"
           (fn [] (let [h (make-harness [(fspec "audit" "now" (fn [] 42))])]
                    (h-op h)
                    (let [rec (vs/getelem (mget (h-track h "_audit") "records") 0)]
                      (t/is-eq (mget rec "actor") "anonymous" "anon")
                      (t/is-eq (mget rec "ts") 42 "ts")))))
    (check "audit-bounds-records" "audit"
           (fn [] (let [h (make-harness [(fspec "audit" "max" 2)])]
                    (h-op h) (h-op h) (h-op h)
                    (let [recs (mget (h-track h "_audit") "records")]
                      (t/is-eq (vs/size recs) 2 "2")
                      (t/is-eq (mget (vs/getelem recs 0) "seq") 2 "seq 2")
                      (t/is-eq (mget (vs/getelem recs 1) "seq") 3 "seq 3")))))

    ;; ---- clienttrack ----
    (check "clienttrack-stable-id-unique-req" "clienttrack"
           (fn [] (let [[server calls] (recording-server nil)
                        h (make-harness [(fspec "clienttrack" "clientName" "Acme" "clientVersion" "2.0.0")] :server server)]
                    (h-ready h) (h-op h) (h-op h)
                    (let [h0 (mget (vs/getprop (nth @calls 0) "fetchdef") "headers")
                          h1 (mget (vs/getprop (nth @calls 1) "fetchdef") "headers")]
                      (t/is-eq (mget h0 "User-Agent") "Acme/2.0.0" "UA")
                      (t/is-eq (mget h0 "X-Client-Id") (mget h1 "X-Client-Id") "same client id")
                      (t/is-true (not= (mget h0 "X-Request-Id") (mget h1 "X-Request-Id")) "diff req id")
                      (t/is-eq (mget (h-track h "_clienttrack") "requests") 2 "2 requests")))))
    (check "clienttrack-does-not-clobber-ua" "clienttrack"
           (fn [] (let [[server calls] (recording-server nil)
                        h (make-harness [(fspec "clienttrack")] :server server)]
                    (h-ready h)
                    (h-op h :headers (vs/jm "User-Agent" "mine"))
                    (t/is-eq (mget (vs/getprop (vs/getprop (nth @calls 0) "fetchdef") "headers") "User-Agent") "mine" "kept"))))
    (check "clienttrack-injected-idgen-session" "clienttrack"
           (fn [] (let [[server calls] (recording-server nil)
                        h (make-harness [(fspec "clienttrack" "sessionId" "S1" "idgen" (fn [k] (str k "-1")))] :server server)]
                    (h-ready h) (h-op h)
                    (let [hh (mget (vs/getprop (nth @calls 0) "fetchdef") "headers")]
                      (t/is-eq (mget hh "X-Client-Id") "S1" "session")
                      (t/is-eq (mget hh "X-Request-Id") "request-1" "req id")))))
    (check "clienttrack-lazy-session" "clienttrack"
           (fn [] (let [[server calls] (recording-server nil)
                        h (make-harness [(fspec "clienttrack")] :server server)]
                    (h-op h)
                    (t/is-some (mget (vs/getprop (vs/getprop (nth @calls 0) "fetchdef") "headers") "X-Client-Id") "lazy session"))))

    ;; ---- paging ----
    (check "paging-stamps-and-reads-headers" "paging"
           (fn [] (let [[server calls] (recording-server
                                        (fn [_n _fd] [(make-response 200 (vs/jm "items" (vs/jt 1 2))
                                                                     (vs/jm "x-next-page" "2" "x-total-count" "5" "link" "</w?page=2>; rel=\"next\"")) nil]))
                        h (make-harness [(fspec "paging" "limit" 2)] :server server)
                        res (h-op h :opname "list" :path "/w")]
                    (t/is-true (boolean (re-find #"[?&]page=1(&|$)" (str (vs/getprop (nth @calls 0) "url")))) "page=1")
                    (t/is-true (boolean (re-find #"[?&]limit=2(&|$)" (str (vs/getprop (nth @calls 0) "url")))) "limit=2")
                    (let [paging (core/oget (get res "result") :paging)]
                      (t/is-eq (mget paging "nextPage") 2 "nextPage")
                      (t/is-eq (mget paging "totalCount") 5 "totalCount")
                      (t/is-eq (mget paging "next") "/w?page=2" "next")
                      (t/is-eq (mget paging "hasMore") true "hasMore")))))
    (check "paging-body-cursor-and-explicit" "paging"
           (fn [] (let [[server calls] (recording-server
                                        (fn [_n _fd] [(make-response 200 (vs/jm "nextCursor" "abc" "hasMore" true) nil) nil]))
                        h (make-harness [(fspec "paging")] :server server)
                        res (h-op h :opname "list" :path "/w" :ctrl (vs/jm "paging" (vs/jm "cursor" "xyz")))]
                    (t/is-true (boolean (re-find #"[?&]cursor=xyz(&|$)" (str (vs/getprop (nth @calls 0) "url")))) "cursor=xyz")
                    (t/is-eq (mget (core/oget (get res "result") :paging) "cursor") "abc" "cursor abc")
                    (t/is-eq (mget (core/oget (get res "result") :paging) "hasMore") true "hasMore"))))
    (check "paging-non-list-not-paged" "paging"
           (fn [] (let [[server calls] (recording-server nil)
                        h (make-harness [(fspec "paging")] :server server)
                        res (h-op h :path "/w/1")]
                    (t/is-false (boolean (re-find #"[?&]page=" (str (vs/getprop (nth @calls 0) "url")))) "no page")
                    (t/is-nil (core/oget (get res "result") :paging) "no paging"))))

    ;; ---- streaming ----
    (check "streaming-streams-items" "streaming"
           (fn [] (let [c (make-clock)
                        [server _calls] (recording-server (fn [_n _fd] [(make-response 200 (vs/jt "a" "b" "c") nil) nil]))
                        h (make-harness [(fspec "streaming" "chunkDelay" 5 "sleep" (clock-sleeper c))] :server server)
                        res (h-op h :opname "list" :path "/w")]
                    (t/is-eq (core/oget (get res "result") :streaming) true "streaming")
                    (let [seen ((core/oget (get res "result") :stream))]
                      (t/is-deep (vec seen) ["a" "b" "c"] "items")
                      (t/is-eq @c 15 "delay")
                      (t/is-eq (mget (h-track h "_streaming") "opened") 1 "opened")))))
    (check "streaming-batches-chunk-size" "streaming"
           (fn [] (let [[server _calls] (recording-server (fn [_n _fd] [(make-response 200 (vs/jt 1 2 3 4 5) nil) nil]))
                        h (make-harness [(fspec "streaming" "chunkSize" 2)] :server server)
                        res (h-op h :opname "list" :path "/w")]
                    (t/is-deep (mapv vec ((core/oget (get res "result") :stream))) [[1 2] [3 4] [5]] "batches"))))
    (check "streaming-non-list-not-streamed" "streaming"
           (fn [] (let [h (make-harness [(fspec "streaming")])
                        res (h-op h)]
                    (t/is-nil (core/oget (get res "result") :streaming) "not streamed"))))

    ;; ---- proxy ----
    (check "proxy-routes-and-agent" "proxy"
           (fn [] (let [[server calls] (recording-server nil)
                        agent-url (atom nil)
                        h (make-harness [(fspec "proxy" "url" "http://proxy:8080"
                                                "agent" (fn [u _t] (reset! agent-url u) (vs/jm "a" 1)))] :server server)]
                    (h-op h)
                    (t/is-eq (mget (vs/getprop (nth @calls 0) "fetchdef") "proxy") "http://proxy:8080" "proxy")
                    (t/is-deep (mget (vs/getprop (nth @calls 0) "fetchdef") "dispatcher") (vs/jm "a" 1) "dispatcher")
                    (t/is-eq @agent-url "http://proxy:8080" "agent url")
                    (t/is-eq (mget (h-track h "_proxy") "routed") 1 "routed"))))
    (check "proxy-bypasses-no-proxy" "proxy"
           (fn [] (let [[server calls] (recording-server nil)
                        h (make-harness [(fspec "proxy" "url" "http://proxy:8080" "noProxy" (vs/jt "api.test"))]
                                        :server server :base "http://api.test")]
                    (h-op h)
                    (t/is-nil (mget (vs/getprop (nth @calls 0) "fetchdef") "proxy") "bypassed"))))
    (check "proxy-inactive-or-no-url-noop" "proxy"
           (fn [] (let [[server calls] (recording-server nil)
                        h (make-harness [(fspec "proxy" "active" false)] :server server)]
                    (h-op h)
                    (t/is-nil (mget (vs/getprop (nth @calls 0) "fetchdef") "proxy") "no proxy inactive")
                    (let [[server2 calls2] (recording-server nil)
                          h2 (make-harness [(fspec "proxy")] :server server2)]
                      (h-op h2)
                      (t/is-nil (mget (vs/getprop (nth @calls2 0) "fetchdef") "proxy") "no proxy no url")))))

    ;; ---- composition ----
    (check "cache-plus-netsim-hit-skips-failure" "cache"
           (fn [] (when (feature-present? "netsim")
                    (let [h (make-harness [(fspec "netsim" "failEvery" 2) (fspec "cache" "ttl" 10000)])]
                      (t/is-eq (get (h-op h :path "/w") "ok") true "1")
                      (t/is-eq (get (h-op h :path "/w") "ok") true "2 (cache hit)")
                      (t/is-eq (mget (h-track h "_netsim") "calls") 1 "1 netsim call")))))
    nil))
