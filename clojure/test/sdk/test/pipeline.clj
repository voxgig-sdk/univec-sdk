;; Univec SDK pipeline unit tests — error/edge branches of the operation
;; utilities that a happy-path op never reaches (missing spec/response/result,
;; 4xx, transport failures, feature ordering, feature-supplied short-circuits,
;; auth header shaping). API-agnostic: reached through the client utility view.
(ns sdk.test.pipeline
  (:require [sdk.core :as core]
            [sdk.client :as client]
            [sdk.features :as features]
            [sdk.testutil :as t]
            [voxgig.struct :as vs]))

(defn- mget [m k] (when (instance? java.util.Map m) (.get ^java.util.Map m k)))

(defn- make-ctx [sdk opname]
  (let [utility (core/get-utility sdk)
        ctx (core/make-context (vs/jm "opname" opname "client" sdk "utility" utility) nil)]
    (when (nil? (core/oget ctx :options)) (core/oset! ctx :options (core/client-options-map sdk)))
    ctx))

(defn- set-points! [ctx pts] (swap! (core/oget ctx :op) assoc :points pts))

(defn- spec-of [& kvs]
  (core/make-spec (apply vs/jm (concat ["step" "s" "method" "GET" "headers" (vs/jm)] kvs))))

(defn- resp [status data headers]
  (let [h (vs/jm)]
    (when (vs/ismap headers) (doseq [item (vs/items headers)] (.put ^java.util.Map h (clojure.string/lower-case (str (vs/getprop item 0))) (vs/getprop item 1))))
    (core/make-response (vs/jm "status" status "statusText" (if (< status 400) "OK" "ERR")
                               "body" "body" "json" (fn [] data) "headers" h))))

(defn- fake-client-opts [opts] {:options (atom opts) :mode (atom "test") :features (atom []) :store (atom {})})

(defn run [rec]
  (let [sdk (client/test-sdk nil nil)
        utility (core/get-utility sdk)]
    (letfn [(chk [name thunk] (t/run-check rec name thunk))]

      ;; ---- make-point ----
      (chk "point-rejects-disallowed-op"
           (fn [] (let [ctx (make-ctx sdk "nope")
                        [_ err] ((core/uget ctx :make-point) ctx)]
                    (t/is-eq (:code err) "point_op_allow" "code"))))
      (chk "point-rejects-no-endpoints"
           (fn [] (let [ctx (make-ctx sdk "load")]
                    (set-points! ctx (vs/jt))
                    (let [[_ err] ((core/uget ctx :make-point) ctx)]
                      (t/is-eq (:code err) "point_no_points" "code")))))
      (chk "point-returns-single-point"
           (fn [] (let [ctx (make-ctx sdk "load")
                        point (vs/jm "parts" (vs/jt "a") "args" (vs/jm "params" (vs/jt)))]
                    (set-points! ctx (vs/jt point))
                    (let [[out err] ((core/uget ctx :make-point) ctx)]
                      (t/is-nil err "no err")
                      (t/is-true (identical? out point) "same point")))))
      (chk "point-short-circuits-preset"
           (fn [] (let [ctx (make-ctx sdk "load")
                        preset (vs/jm "parts" (vs/jt "a"))]
                    (core/out-set! ctx "point" preset)
                    (let [[out err] ((core/uget ctx :make-point) ctx)]
                      (t/is-nil err "no err")
                      (t/is-true (identical? out preset) "preset")))))
      ;; gotcha #2: a feature (rbac) places an error in out.point; make-point
      ;; must surface it before any network use.
      (chk "point-surfaces-feature-error"
           (fn [] (let [ctx (make-ctx sdk "load")
                        denial (core/ctx-error ctx "rbac_denied" "denied")]
                    (core/out-set! ctx "point" denial)
                    (let [[out err] ((core/uget ctx :make-point) ctx)]
                      (t/is-nil out "no point")
                      (t/is-eq (:code err) "rbac_denied" "denied")))))

      ;; ---- make-spec ----
      (chk "spec-short-circuits-preset"
           (fn [] (let [ctx (make-ctx sdk "load")
                        preset (spec-of "method" "GET")]
                    (core/out-set! ctx "spec" preset)
                    (let [[out err] ((core/uget ctx :make-spec) ctx)]
                      (t/is-nil err "no err")
                      (t/is-true (identical? out preset) "preset")))))

      ;; ---- make-response ----
      (chk "response-guards-missing"
           (fn [] (let [ctx (make-ctx sdk "load")]
                    (core/oset! ctx :spec nil) (core/oset! ctx :response (resp 200 nil nil)) (core/oset! ctx :result (core/make-result (vs/jm)))
                    (t/is-eq (:code (second ((core/uget ctx :make-response) ctx))) "response_no_spec" "no spec")
                    (let [ctx2 (make-ctx sdk "load")]
                      (core/oset! ctx2 :spec (spec-of)) (core/oset! ctx2 :response nil) (core/oset! ctx2 :result (core/make-result (vs/jm)))
                      (t/is-eq (:code (second ((core/uget ctx2 :make-response) ctx2))) "response_no_response" "no resp"))
                    (let [ctx3 (make-ctx sdk "load")]
                      (core/oset! ctx3 :spec (spec-of)) (core/oset! ctx3 :response (resp 200 nil nil)) (core/oset! ctx3 :result nil)
                      (t/is-eq (:code (second ((core/uget ctx3 :make-response) ctx3))) "response_no_result" "no result")))))
      (chk "response-4xx-sets-err-copies-headers"
           (fn [] (let [ctx (make-ctx sdk "load")]
                    (core/oset! ctx :spec (spec-of)) (core/oset! ctx :response (resp 404 nil (vs/jm "x-a" "1"))) (core/oset! ctx :result (core/make-result (vs/jm)))
                    (let [[_ err] ((core/uget ctx :make-response) ctx) result (core/oget ctx :result)]
                      (t/is-nil err "no err tuple")
                      (t/is-some (core/oget result :err) "result err")
                      (t/is-eq (core/oget result :status) 404 "404")
                      (t/is-eq (mget (core/oget result :headers) "x-a") "1" "header")
                      (t/is-eq (core/oget result :ok) false "not ok")))))
      (chk "response-2xx-parses-body-ok"
           (fn [] (let [ctx (make-ctx sdk "load")]
                    (core/oset! ctx :spec (spec-of)) (core/oset! ctx :response (resp 200 (vs/jm "v" 1) nil)) (core/oset! ctx :result (core/make-result (vs/jm)))
                    ((core/uget ctx :make-response) ctx)
                    (t/is-eq (core/oget (core/oget ctx :result) :ok) true "ok")
                    (t/is-deep (core/oget (core/oget ctx :result) :body) (vs/jm "v" 1) "body"))))
      (chk "response-records-explain"
           (fn [] (let [ctx (make-ctx sdk "load")]
                    (core/oset! (core/oget ctx :ctrl) :explain (vs/jm))
                    (core/oset! ctx :spec (spec-of)) (core/oset! ctx :response (resp 200 (vs/jm "v" 2) nil)) (core/oset! ctx :result (core/make-result (vs/jm)))
                    ((core/uget ctx :make-response) ctx)
                    (t/is-some (mget (core/oget (core/oget ctx :ctrl) :explain) "result") "explain result"))))

      ;; ---- make-result ----
      (chk "result-guards-missing"
           (fn [] (let [ctx (make-ctx sdk "load")]
                    (core/oset! ctx :spec nil) (core/oset! ctx :result (core/make-result (vs/jm)))
                    (t/is-eq (:code (second ((core/uget ctx :make-result) ctx))) "result_no_spec" "no spec")
                    (let [ctx2 (make-ctx sdk "load")]
                      (core/oset! ctx2 :spec (spec-of)) (core/oset! ctx2 :result nil)
                      (t/is-eq (:code (second ((core/uget ctx2 :make-result) ctx2))) "result_no_result" "no result")))))
      (chk "result-list-wraps-into-entities"
           (fn [] (let [made (atom [])
                        ctx (core/make-context (vs/jm "opname" "list" "client" sdk "utility" utility
                                                      "entity" {:make (fn [] {:data-set (fn [d] (swap! made conj d))})}) nil)]
                    (core/oset! ctx :spec (spec-of))
                    (core/oset! ctx :result (core/make-result (vs/jm "ok" true "resdata" (vs/jt (vs/jm "a" 1) (vs/jm "a" 2)))))
                    (let [[result err] ((core/uget ctx :make-result) ctx)]
                      (t/is-nil err "no err")
                      (t/is-eq (vs/size (core/oget result :resdata)) 2 "2")
                      (t/is-eq (count @made) 2 "made 2")))))
      (chk "result-empty-list"
           (fn [] (let [ctx (core/make-context (vs/jm "opname" "list" "client" sdk "utility" utility
                                                     "entity" {:make (fn [] {:data-set (fn [_])})}) nil)]
                    (core/oset! ctx :spec (spec-of))
                    (core/oset! ctx :result (core/make-result (vs/jm "ok" true "resdata" (vs/jt))))
                    (let [[result _] ((core/uget ctx :make-result) ctx)]
                      (t/is-eq (vs/size (core/oget result :resdata)) 0 "empty")))))

      ;; ---- make-request ----
      (chk "request-guards-missing-spec"
           (fn [] (let [ctx (make-ctx sdk "load")]
                    (core/oset! ctx :spec nil)
                    (t/is-eq (:code (second ((core/uget ctx :make-request) ctx))) "request_no_spec" "no spec"))))
      (chk "request-transport-error-lands-on-response"
           (fn [] (let [boom (core/make-error-obj "boom" "boom")
                        u (core/get-utility sdk) _ (core/oset! u :fetcher (fn [_c _u _f] [nil boom]))
                        ctx (core/make-context (vs/jm "opname" "load" "client" sdk "utility" u) nil)]
                    (core/oset! ctx :options (core/client-options-map sdk))
                    (core/oset! ctx :spec (spec-of "base" "http://h" "path" "a"))
                    (let [[response err] ((core/uget ctx :make-request) ctx)]
                      (t/is-nil err "no err tuple")
                      (t/is-true (identical? (core/oget response :err) boom) "response err")))))
      (chk "request-nil-transport-becomes-response-error"
           (fn [] (let [u (core/get-utility sdk) _ (core/oset! u :fetcher (fn [_c _u _f] [nil nil]))
                        ctx (core/make-context (vs/jm "opname" "load" "client" sdk "utility" u) nil)]
                    (core/oset! ctx :options (core/client-options-map sdk))
                    (core/oset! ctx :spec (spec-of "base" "http://h" "path" "a"))
                    (let [[response err] ((core/uget ctx :make-request) ctx)]
                      (t/is-nil err "no err tuple")
                      (t/is-some (core/oget response :err) "response err")))))
      (chk "request-wraps-normal-response"
           (fn [] (let [u (core/get-utility sdk)
                        _ (core/oset! u :fetcher (fn [_c _u _f] [(vs/jm "status" 200 "statusText" "OK" "headers" (vs/jm) "json" (fn [] (vs/jm "a" 1)) "body" "b") nil]))
                        ctx (core/make-context (vs/jm "opname" "load" "client" sdk "utility" u) nil)]
                    (core/oset! ctx :options (core/client-options-map sdk))
                    (core/oset! ctx :spec (spec-of "base" "http://h" "path" "a"))
                    (let [[response err] ((core/uget ctx :make-request) ctx)]
                      (t/is-nil err "no err")
                      (t/is-eq (core/oget response :status) 200 "200")))))
      (chk "request-fetchdef-error-surfaces"
           (fn [] (let [u (core/get-utility sdk)
                        _ (core/oset! u :make-fetch-def (fn [_ctx] [nil (core/make-error-obj "fetchdef_boom" "boom")]))
                        ctx (core/make-context (vs/jm "opname" "load" "client" sdk "utility" u) nil)]
                    (core/oset! ctx :options (core/client-options-map sdk))
                    (core/oset! ctx :spec (spec-of "base" "http://h" "path" "a"))
                    (let [[response err] ((core/uget ctx :make-request) ctx)]
                      (t/is-nil err "no err tuple")
                      (t/is-eq (:code (core/oget response :err)) "fetchdef_boom" "code")))))

      ;; ---- make-fetch-def ----
      (chk "fetchdef-guards-missing-spec"
           (fn [] (let [ctx (make-ctx sdk "load")]
                    (core/oset! ctx :spec nil)
                    (t/is-eq (:code (second ((core/uget ctx :make-fetch-def) ctx))) "fetchdef_no_spec" "no spec"))))
      (chk "fetchdef-serialises-body-inits-result"
           (fn [] (let [ctx (make-ctx sdk "load")]
                    (core/oset! ctx :result nil)
                    (core/oset! ctx :spec (spec-of "method" "POST" "base" "http://h" "path" "a" "body" (vs/jm "x" 1)))
                    (let [[fetchdef err] ((core/uget ctx :make-fetch-def) ctx)]
                      (t/is-nil err "no err")
                      (t/is-true (string? (vs/getprop fetchdef "body")) "body string")
                      (t/is-some (core/oget ctx :result) "result created")))))

      ;; ---- done + make-error ----
      (chk "done-returns-resdata"
           (fn [] (let [ctx (make-ctx sdk "load")]
                    (core/oset! ctx :result (core/make-result (vs/jm "ok" true "resdata" 42)))
                    (t/is-eq ((core/uget ctx :done) ctx) 42 "42"))))
      (chk "done-raises-when-not-ok"
           (fn [] (let [ctx (make-ctx sdk "load")]
                    (core/oset! ctx :result (core/make-result (vs/jm "ok" false)))
                    (t/is-throws (fn [] ((core/uget ctx :done) ctx)) nil "raises"))))
      (chk "make-error-returns-resdata-when-throw-disabled"
           (fn [] (let [ctx (make-ctx sdk "load")]
                    (core/oset! (core/oget ctx :ctrl) :throw false)
                    (core/oset! ctx :result (core/make-result (vs/jm "ok" false "resdata" "fallback")))
                    (t/is-eq ((core/uget ctx :make-error) ctx nil) "fallback" "fallback"))))
      (chk "make-error-records-explain"
           (fn [] (let [ctx (make-ctx sdk "load")]
                    (core/oset! (core/oget ctx :ctrl) :throw false)
                    (core/oset! (core/oget ctx :ctrl) :explain (vs/jm))
                    (core/oset! ctx :result (core/make-result (vs/jm "ok" false)))
                    ((core/uget ctx :make-error) ctx nil)
                    (t/is-some (mget (core/oget (core/oget ctx :ctrl) :explain) "err") "explain err"))))
      (chk "make-error-preserves-code"
           (fn [] (let [ctx (make-ctx sdk "load")]
                    (t/is-throws (fn [] ((core/uget ctx :make-error) ctx (core/ctx-error ctx "rbac_denied" "denied")))
                                 "rbac_denied" "preserves code"))))

      ;; ---- feature ordering (gotcha #4) ----
      (chk "feature-add-appends-in-order"
           (fn [] (let [ctx (make-ctx sdk "load")]
                    (reset! (:features sdk) [])
                    (let [a (features/base-feature) b (features/base-feature)]
                      ((core/uget ctx :feature-add) ctx a)
                      ((core/uget ctx :feature-add) ctx b)
                      (t/is-true (= [a b] @(:features sdk)) "append order")))))
      (chk "feature-add-before-after-replace"
           (fn [] (let [ctx (make-ctx sdk "load")
                        named (fn [name] (let [f (features/base-feature)] (swap! f assoc :name name) f))
                        names (fn [] (mapv core/feature-get-name @(:features sdk)))]
                    (reset! (:features sdk) [])
                    ((core/uget ctx :feature-add) ctx (named "a"))
                    ((core/uget ctx :feature-add) ctx (named "b"))
                    (t/is-deep (names) ["a" "b"] "ab")
                    (let [before (named "z1")] (swap! before assoc :_options (vs/jm "__before__" "b")) ((core/uget ctx :feature-add) ctx before))
                    (t/is-deep (names) ["a" "z1" "b"] "before")
                    (let [after (named "z2")] (swap! after assoc :_options (vs/jm "__after__" "a")) ((core/uget ctx :feature-add) ctx after))
                    (t/is-deep (names) ["a" "z2" "z1" "b"] "after")
                    (let [replace (named "z3")] (swap! replace assoc :_options (vs/jm "__replace__" "z1")) ((core/uget ctx :feature-add) ctx replace))
                    (t/is-deep (names) ["a" "z2" "z3" "b"] "replace")
                    (let [miss (named "z4")] (swap! miss assoc :_options (vs/jm "__before__" "missing")) ((core/uget ctx :feature-add) ctx miss))
                    (t/is-deep (names) ["a" "z2" "z3" "b" "z4"] "append fallback"))))

      ;; ---- feature order (PR review #2) ----
      ;; make-options resolves the feature add-order into
      ;; __derived__.featureorder: a map defaults test-first (so the test mock
      ;; is the base transport), an explicit array preserves the developer
      ;; order, and a map without test is deterministic (names sorted).
      (let [resolve-order
            (fn [feature]
              (let [ctx (make-ctx sdk "load")]
                (core/oset! ctx :options (vs/jm "feature" feature))
                (core/oset! ctx :config (vs/jm "options" (vs/jm)))
                (let [o ((core/uget ctx :make-options) ctx)]
                  o)))]
        (chk "feature-order-map-test-first"
             (fn [] (let [o (resolve-order (vs/jm "metrics" (vs/jm "active" true) "test" (vs/jm "active" true)))]
                      (t/is-deep (vec (vs/getpath o "__derived__.featureorder")) ["test" "metrics"] "test-first"))))
        (chk "feature-order-array-preserves-order"
             (fn [] (let [o (resolve-order (vs/jt (vs/jm "name" "metrics" "active" true)
                                                  (vs/jm "name" "test" "active" true)))]
                      (t/is-deep (vec (vs/getpath o "__derived__.featureorder")) ["metrics" "test"] "explicit order")
                      (t/is-eq (vs/getpath o "feature.metrics.active") true "metrics normalized")
                      (t/is-eq (vs/getpath o "feature.test.active") true "test normalized"))))
        (chk "feature-order-no-test-deterministic"
             (fn [] (let [o (resolve-order (vs/jm "retry" (vs/jm "active" true) "cache" (vs/jm "active" true)))]
                      (t/is-deep (vec (vs/getpath o "__derived__.featureorder")) ["cache" "retry"] "sorted")))))

      ;; ---- prepare-auth ----
      (let [auth-ctx (fn [opts headers]
                       (let [c (fake-client-opts opts)
                             ctx (core/make-context (vs/jm "client" c "utility" utility "opname" "load") nil)]
                         (core/oset! ctx :spec (when headers (core/make-spec (vs/jm "headers" headers "step" "s"))))
                         ctx))]
        (chk "auth-guards-missing-spec"
             (fn [] (let [ctx (auth-ctx (vs/jm "auth" (vs/jm "prefix" "") "apikey" "K") nil)]
                      (t/is-eq (:code (second ((core/uget ctx :prepare-auth) ctx))) "auth_no_spec" "no spec"))))
        (chk "auth-apikey-with-prefix-space-joined"
             (fn [] (let [ctx (auth-ctx (vs/jm "apikey" "K" "auth" (vs/jm "prefix" "Bearer")) (vs/jm))]
                      ((core/uget ctx :prepare-auth) ctx)
                      (t/is-eq (mget (core/oget (core/oget ctx :spec) :headers) "authorization") "Bearer K" "joined"))))
        (chk "auth-raw-apikey"
             (fn [] (let [ctx (auth-ctx (vs/jm "apikey" "K" "auth" (vs/jm "prefix" "")) (vs/jm))]
                      ((core/uget ctx :prepare-auth) ctx)
                      (t/is-eq (mget (core/oget (core/oget ctx :spec) :headers) "authorization") "K" "raw"))))
        (chk "auth-empty-apikey-drops"
             (fn [] (let [ctx (auth-ctx (vs/jm "apikey" "" "auth" (vs/jm "prefix" "Bearer")) (vs/jm "authorization" "stale"))]
                      ((core/uget ctx :prepare-auth) ctx)
                      (t/is-nil (mget (core/oget (core/oget ctx :spec) :headers) "authorization") "dropped"))))
        (chk "auth-public-api-drops"
             (fn [] (let [ctx (auth-ctx (vs/jm "apikey" "K") (vs/jm "authorization" "stale"))]
                      ((core/uget ctx :prepare-auth) ctx)
                      (t/is-nil (mget (core/oget (core/oget ctx :spec) :headers) "authorization") "dropped"))))
        (chk "auth-missing-apikey-drops"
             (fn [] (let [ctx (auth-ctx (vs/jm "auth" (vs/jm "prefix" "Bearer")) (vs/jm "authorization" "stale"))]
                      ((core/uget ctx :prepare-auth) ctx)
                      (t/is-nil (mget (core/oget (core/oget ctx :spec) :headers) "authorization") "dropped")))))

      ;; ---- result helpers ----
      (chk "result-headers-non-hash-empty"
           (fn [] (let [ctx (make-ctx sdk "load")]
                    (core/oset! ctx :response (core/make-response (vs/jm "status" 200)))
                    (core/oset! ctx :result (core/make-result (vs/jm)))
                    ((core/uget ctx :result-headers) ctx)
                    (t/is-eq (vs/size (core/oget (core/oget ctx :result) :headers)) 0 "empty"))))
      (chk "result-body-skips-when-absent"
           (fn [] (let [ctx (make-ctx sdk "load")]
                    (core/oset! ctx :response (core/make-response (vs/jm "status" 200 "json" (fn [] (vs/jm "a" 1)) "body" nil)))
                    (core/oset! ctx :result (core/make-result (vs/jm)))
                    ((core/uget ctx :result-body) ctx)
                    (t/is-nil (core/oget (core/oget ctx :result) :body) "no body"))))
      nil)))
