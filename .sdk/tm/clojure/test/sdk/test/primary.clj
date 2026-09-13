;; Univec SDK primary utility tests — the utility object exposes every
;; pipeline member and the vendored struct library, and a few core behaviours.
(ns sdk.test.primary
  (:require [sdk.core :as core]
            [sdk.client :as client]
            [sdk.testutil :as t]
            [sdk.test.omni :as omni]
            [voxgig.struct :as vs]
            [clojure.string :as str])
  (:import [java.util Map]))

;; THE SHARED CORPUS.
;;
;; The checks below assert against inputs written here; this drives
;; .sdk/test/test.json -> "primary" through the same utilities, so the cases
;; cannot drift from the reference implementation. That is what moves clojure
;; from the MIRRORED parity tier to FULL — a mirrored suite cannot notice a
;; corpus case that changed, or one that was added.

(def ^:private CORPUS "../.sdk/test/test.json")

(defn- lower-headers [m]
  ;; Header names arrive in any case and the contract is lowercase; the SDK
  ;; copies them verbatim, so the driver normalises, as the lua reference does.
  (when (vs/ismap m)
    (let [out (vs/jm)]
      (doseq [k (vs/keysof m)] (vs/setprop out (str/lower-case k) (vs/getprop m k)))
      out)))

(defn- neutral
  "A struct map with STRING keys, from this port's keyword-keyed atom.

   spec/result/response are atoms wrapping {:base ... :status-text ...}; the
   corpus is camelCase and string-keyed, so a raw deref matches nothing.
   status-text is spelled statusText here for the same reason."
  [v]
  (let [m (if (instance? clojure.lang.Atom v) (deref v) v)]
    (if-not (map? m)
      m
      (let [out (vs/jm)]
        (doseq [[k val] m]
          (let [ks (if (keyword? k) (name k) (str k))
                ks (case ks "status-text" "statusText" ks)
                v0 (if (instance? clojure.lang.Atom val) (deref val) val)
                ;; An SDK error object is keyword-keyed with :msg; the contract
                ;; spells it err.message, so a raw copy reads null.
                v1 (if (and (map? v0) (core/sdk-error? v0))
                     (vs/jm "message" (str (:msg v0)))
                     v0)]
            (vs/setprop out ks v1)))
        out))))

(defn- publish-ctx
  "Write the mutated spec/result/response back onto the corpus map.

   The match reads entry.ctx — the raw corpus map — while the utilities mutate
   the live objects hanging off the context, so without this every ctx.*
   assertion reads null."
  [ctxmap ctx]
  (doseq [[k kw] [["spec" :spec] ["result" :result] ["response" :response]
                  ["err" :err]]]
    (when-let [v (core/oget ctx kw)]
      (vs/setprop ctxmap k (neutral v))))
  ctxmap)

(defn- corpus-ctx
  "A LIVE context from a corpus map: the utilities read and MUTATE spec, result
   and response, so a bare map leaves them nothing to work on.

   The context is an ATOM here, not a struct map — core/oget and core/oset!
   with KEYWORD keys are its accessors, and vs/setprop on it silently does
   nothing."
  [sdk utility ctxmap]
  (let [ctxmap (if (vs/ismap ctxmap) ctxmap (vs/jm))
        opname (vs/getprop ctxmap "opname")
        ctx (core/make-context
              (vs/jm "opname" (or opname "") "client" sdk "utility" utility) nil)]
    (when (nil? (core/oget ctx :options))
      (core/oset! ctx :options (core/client-options-map sdk)))
    (when-let [sp (vs/getprop ctxmap "spec")]
      (when (vs/ismap sp) (core/oset! ctx :spec (core/make-spec sp))))
    (when-let [rs (vs/getprop ctxmap "result")]
      (when (vs/ismap rs) (core/oset! ctx :result (core/make-result rs))))
    (when-let [rp (vs/getprop ctxmap "response")]
      (when (vs/ismap rp)
        (let [resp (core/make-response rp)]
          (when-let [lh (lower-headers (vs/getprop rp "headers"))]
            (core/oset! resp :headers lh))
          ;; result-body reads the response's json thunk, not its body; the
          ;; corpus supplies a plain body, so wrap it as the other drivers do.
          (when-let [b (vs/getprop rp "body")]
            (core/oset! resp :json (fn [] b)))
          (core/oset! ctx :response resp))))
    (doseq [[k kw] [["point" :point] ["reqdata" :reqdata]
                    ["reqmatch" :reqmatch] ["data" :data]]]
      (when-let [v (vs/getprop ctxmap k)] (core/oset! ctx kw v)))
    ctx))

(defn run [rec]
  (let [sdk (client/test-sdk nil nil)
        utility (core/get-utility sdk)]

    (t/run-check rec "primary-utility-members-exist"
      (fn [] (doseq [k [:clean :done :make-error :feature-add :feature-hook :feature-init :fetcher
                        :make-fetch-def :make-context :make-options :make-request :make-response :make-result
                        :make-point :make-spec :make-url :param :prepare-auth :prepare-body :prepare-headers
                        :prepare-method :prepare-params :prepare-path :prepare-query :result-basic :result-body
                        :result-headers :transform-request :transform-response]]
               (t/is-some (get (deref utility) k) (str "utility " k)))))

    (t/run-check rec "primary-struct-exposed"
      (fn [] (let [s (:struct (deref utility))]
               (t/is-true (some? s) "struct present")
               (doseq [k [:clone :getprop :getpath :setprop :setpath :merge :walk :inject :transform
                          :validate :select :items :keysof :escre :escurl :join :jsonify :stringify :typify
                          :getelem :delprop :haskey :size :isempty :isnode :ismap :islist]]
                 (t/is-true (fn? (get s k)) (str "struct " k))))))

    (t/run-check rec "primary-prepare-method"
      (fn [] (let [ctx (core/make-context (vs/jm "opname" "create" "client" sdk "utility" utility) nil)]
               (t/is-eq ((core/uget ctx :prepare-method) ctx) "POST" "POST"))))

    (t/run-check rec "primary-prepare-path"
      (fn [] (let [ctx (core/make-context (vs/jm "opname" "load" "client" sdk "utility" utility) nil)]
               (core/oset! ctx :point (vs/jm "parts" (vs/jt "api" "planet" "{id}") "args" (vs/jm "params" (vs/jt))))
               (t/is-eq ((core/uget ctx :prepare-path) ctx) "api/planet/{id}" "path"))))

    (t/run-check rec "primary-make-fetch-def"
      (fn [] (let [ctx (core/make-context (vs/jm "opname" "load" "client" sdk "utility" utility) nil)]
               (core/oset! ctx :options (core/client-options-map sdk))
               (core/oset! ctx :spec (core/make-spec (vs/jm "base" "http://localhost:8080" "prefix" "/api"
                                                           "path" "items/{id}" "suffix" ""
                                                           "params" (vs/jm "id" "item01") "query" (vs/jm)
                                                           "headers" (vs/jm "content-type" "application/json")
                                                           "method" "GET" "step" "start")))
               (core/oset! ctx :result (core/make-result (vs/jm)))
               (let [[fetchdef err] ((core/uget ctx :make-fetch-def) ctx)]
                 (t/is-nil err "no err")
                 (t/is-eq (vs/getprop fetchdef "method") "GET" "GET")
                 (t/is-true (str/includes? (str (vs/getprop fetchdef "url")) "/api/items/item01") "url includes")))))
    nil))

(defn run-corpus
  "Drive every primary section of the shared corpus through this SDK.

   The engine is the VENDORED omni runner (sdk.test.omni), not a hand-written
   entry loop: each section names its corpus node and the subject that drives
   it, and omni decides whether the result, the match and the error
   expectations hold. omni raises on the first failing entry of a set, so a
   green section counts its whole set - counted at the SUBJECT, from
   sdk.test.omni's execution counter, and failed when it disagrees with the
   set handed over, so the number cannot survive a stopped engine."
  [rec]
  (let [alltests (omni/load-spec CORPUS)
        primary (get alltests "primary")
        sdk (client/test-sdk nil nil)
        mkrunner (omni/make-runner alltests sdk)
        utility (core/get-utility sdk)
        u (fn [k] (get (deref utility) k))
        setup-of (fn [nm] (omni/->struct (get-in primary [nm "DEF" "setup" "a"])))
        client-for (fn [nm] (let [su (setup-of nm)]
                              (if (vs/ismap su) (client/test-sdk nil su) sdk)))
        ;; make-spec and prepare-auth read defaults off the CLIENT, as the ts
        ;; reference does via client.options(), so a section's DEF.setup cannot
        ;; reach them through ctx options.
        spec-sdk (client-for "makeSpec")
        auth-sdk (client-for "prepareAuth")
        ran (atom 0)
        npass (atom 0)
        fails (atom [])
        ;; One section, driven with a ctx built from the corpus entry.
        runset (fn [nm cl f]
                 (let [node (get-in primary [nm "basic"])]
                   (when (nil? node)
                     (throw (ex-info (str "corpus section missing: " nm) {})))
                   (swap! ran inc)
                   (let [rp (mkrunner nm)
                         testset (get node "set")
                         n (count testset)]
                     ;; A section whose `set` is present but empty runs nothing
                     ;; and raises nothing - no passes, and green. omni refuses
                     ;; that under a versioned spec (`checkset`, with an
                     ;; `empty: true` opt-out); the shared corpus is lenient v0,
                     ;; so it is refused here. A section with no `set` at all is
                     ;; left to omni, whose message for it is the better one.
                     (if (and (sequential? testset) (zero? n)
                              (not (true? (get node "empty"))))
                       (swap! fails conj [nm "corpus section has an empty set"])
                       (try
                       ;; omni APPLIES the resolved args, so an args-style entry
                       ;; calls the subject with more than one - variadic, and the
                       ;; extra arg reaches the section through `more`.
                       ;;
                         ;; `executed` is the engine's own count for this set
                         ;; (sdk.test.omni counts inside the subject wrapper),
                         ;; NOT the section's declared size: a number derived
                         ;; from the spec prints the same whether the engine ran
                         ;; or was never called, so it could never show a
                         ;; stoppage.
                         (let [executed (long (or ((:runsetflags rp) node {:name nm}
                                                   (fn [& as]
                                                     (let [ctxmap (first as)
                                                           more (second as)
                                                           ctx (corpus-ctx cl (core/get-utility cl) ctxmap)
                                                           out (f ctx ctxmap more)]
                                                       ;; ctxmap is the LIVE map behind omni's
                                                       ;; ctx view, so this write is what
                                                       ;; `match: {ctx: ...}` reads.
                                                       (publish-ctx ctxmap ctx)
                                                       out)))
                                                  0))]
                           (if (not= executed n)
                             (swap! fails conj
                                    [nm (str "the engine ran " executed " of the section's "
                                             n " entries")])
                             (swap! npass + executed)))
                         (catch Throwable err
                           (swap! fails conj [nm (or (ex-message err) (str err))])))))))
        argof (fn [ctxmap k] (vs/getprop ctxmap k))]

    (t/run-check rec "primary-corpus"
      (fn []
        (runset "done" sdk              (fn [c _ _2] ((u :done) c)))
        (runset "makeUrl" sdk           (fn [c _ _2] (first ((u :make-url) c))))
        (runset "makeRequest" sdk       (fn [c _ _2] (first ((u :make-request) c))))
        (runset "makeResponse" sdk      (fn [c _ _2] (first ((u :make-response) c))))
        (runset "makeSpec" spec-sdk     (fn [c _ _2] (first ((u :make-spec) c))))
        (runset "prepareAuth" auth-sdk  (fn [c _ _2] (first ((u :prepare-auth) c))))
        (runset "prepareBody" sdk       (fn [c _ _2] ((u :prepare-body) c)))
        (runset "prepareHeaders" sdk    (fn [c _ _2] ((u :prepare-headers) c)))
        (runset "prepareMethod" sdk     (fn [c _ _2] ((u :prepare-method) c)))
        (runset "prepareParams" sdk     (fn [c _ _2] ((u :prepare-params) c)))
        (runset "preparePath" sdk       (fn [c _ _2] ((u :prepare-path) c)))
        (runset "prepareQuery" sdk      (fn [c _ _2] ((u :prepare-query) c)))
        (runset "resultBasic" sdk       (fn [c _ _2] (neutral ((u :result-basic) c))))
        (runset "resultBody" sdk        (fn [c _ _2] (neutral ((u :result-body) c))))
        (runset "resultHeaders" sdk     (fn [c _ _2] (neutral ((u :result-headers) c))))
        (runset "transformRequest" sdk  (fn [c _ _2] ((u :transform-request) c)))
        (runset "transformResponse" sdk (fn [c _ _2] ((u :transform-response) c)))
        (runset "makeOptions" sdk       (fn [c m _2]
                                         (core/oset! c :config (argof m "config"))
                                         (core/oset! c :options (argof m "options"))
                                         ((u :make-options) c)))
        (runset "makeContext" sdk       (fn [c _ _2]
                                         (let [op (core/oget c :op)]
                                           (vs/jm "op" (neutral op)))))
        (runset "makeError" sdk         (fn [c _ err] (first ((u :make-error) c err))))
        (runset "operator" sdk          (fn [_ m _2] (neutral (core/make-operation m))))
        (runset "param" sdk             (fn [c _ pd] ((u :param) c pd)))

        (let [np @npass nf (count @fails)]
          (doseq [[nm msg] @fails] (println "PRIMARY-FAIL" nm "-" msg))
          (println "PRIMARY CORPUS: PASS" np " FAIL" nf)
          (t/is-true (< 0 @ran) "the primary corpus executed no sections")
          (t/is-true (< 0 np) "the primary corpus executed no cases")
          (t/is-true (= 0 nf) (str nf " primary corpus failures")))))))
