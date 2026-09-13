;; Univec SDK secrets feature behaviour tests.
;;
;; The contract under test: the `apikey` OPTION keeps its exact old meaning
;; and always wins, because the feature places it FIRST in the provider
;; chain (a `memory` store named `options`) - explicit-beats-lookup falls
;; out of sekreto's first-hit rule rather than from special-case logic.
;; With the feature inactive nothing changes at all. With it active and the
;; option unset, the chain supplies the credential instead. A provider MISS
;; falls through unauthenticated; a provider ERROR FAILS the operation.
;;
;; EVERY CASE HERE BUILDS A LIVE CLIENT (client/make-sdk with
;; `system.fetch`), never client/test-sdk and never the sdk.test.feature
;; harness. Both of those replace `ctx.utility.fetcher` with an in-memory
;; mock, so a counter hung off system.fetch is NEVER REACHED - under a test
;; client both "no request was sent" and "the call failed" hold for a
;; healthy SDK carrying no secrets feature at all, and the pair asserts
;; nothing. An assertion that cannot fail pins no rule.
;;
;; So each fail-closed case proves its own counter FIRST, with the same
;; construction and a WORKING provider: one request must reach system.fetch
;; carrying the resolved credential. Only then does a zero from the broken
;; provider mean REFUSED rather than UNWIRED. And the failure is matched on
;; THE PROVIDER'S OWN MESSAGE, so an unrelated failure (a missing route, a
;; blocked op) cannot stand in for fail-closed.
;;
;; This file lives in the `feature/` container of the test tree on purpose:
;; it is generated only for a project whose model selects `secrets`, and
;; sdk.test-runner reaches it through the same sdk.config wiring the
;; feature itself is registered by.
(ns sdk.test.feature.secrets
  (:require [clojure.string :as str]
            [sdk.core :as core]
            [sdk.client :as client]
            [sdk.feature.secrets :as secrets]
            [sdk.testutil :as t]
            [voxgig.sekreto :as sekreto]
            [voxgig.sekreto.provider :as provider]
            [voxgig.struct :as vs]))


(def ^:private BASE "http://secrets.test/api")

;; Named explicitly: a project that narrows the default allow.op set would
;; otherwise turn these into a false RED (the control leg refused before it
;; reached the transport), and the rule under test lives at the transport,
;; downstream of the allow gate either way.
(def ^:private ALLOWOP "create,update,load,list,remove,command,direct,graphql")


;; ---------------------------------------------------------------------------
;; The transport under test: a recording system.fetch. "Sent" is a fact
;; about the wire, not about a mock somewhere inside the pipeline.
;; ---------------------------------------------------------------------------

(defn- response [status data]
  (vs/jm "status" status "statusText" (if (< status 400) "OK" "ERR")
         "headers" (vs/jm) "body" "not-used" "json" (fn [] data)))


;; `reply` is (fn [n url fetchdef] -> [res err]); nil means 200 {ok true}.
;; The authorization header is snapshotted AS A STRING at call time: the
;; fetchdef's header map is the live spec map the retry rewrites IN PLACE,
;; so holding the map would make every recorded call show the last token.
(defn- counting-fetch
  ([] (counting-fetch nil))
  ([reply]
   (let [calls (atom [])
         stub {:calls calls}]
     (assoc stub :fetch
            (fn [url fetchdef]
              (let [headers (vs/getprop fetchdef "headers")
                    auth (when (vs/ismap headers) (vs/getprop headers "authorization"))
                    n (inc (count @calls))]
                (swap! calls conj {:url url
                                   :auth (when (some? auth) (str auth))
                                   :method (vs/getprop fetchdef "method")
                                   :body (vs/getprop fetchdef "body")})
                (if reply
                  (reply n url fetchdef)
                  [(response 200 (vs/jm "ok" true "n" n)) nil])))))))


(defn- sent [stub] (count (deref (:calls stub))))
(defn- call-at [stub i] (nth (deref (:calls stub)) i nil))

;; What went out, for a failure message that names the leak rather than
;; just its count.
(defn- wire [stub]
  (str/join ", " (map (fn [c] (str (:url c) " auth=" (pr-str (:auth c))))
                      (deref (:calls stub)))))


;; A result, summarised. NEVER pr-str a raw result: an SDK error carries
;; its context, the context carries the client, and the client carries the
;; root context - so printing one is an infinite walk (a StackOverflowError,
;; and it fires while BUILDING an assertion message, which turns a passing
;; test red for the wrong reason).
(defn- brief [res]
  (if (vs/ismap res)
    (let [err (vs/getprop res "err")]
      (str "{ok=" (vs/getprop res "ok")
           " status=" (vs/getprop res "status")
           (if (some? err)
             (str " err=" (pr-str (core/err-code err)) ":" (pr-str (core/err-msg err)))
             "")
           "}"))
    (str res)))


;; ---------------------------------------------------------------------------
;; Providers. `reify`, NEVER `defrecord`: make-options runs the options
;; through vs/merge and vs/validate, which deep-copy every java.util.Map -
;; and a defrecord IS one, so it would arrive at the chain as a plain
;; LinkedHashMap with the protocol gone. A reify is not a Map and survives.
;; ---------------------------------------------------------------------------

(defn- fixed-provider [name value]
  (reify provider/Provider
    (lookup [_ n] (when (= n name) value))
    (describe [_] "fixed:test")))

(defn- broken-provider [msg]
  (reify provider/Provider
    (lookup [_ _] (throw (sekreto/sekretoerror msg)))
    (describe [_] "broken:test")))

(defn- miss-provider []
  (reify provider/Provider
    (lookup [_ _] nil)
    (describe [_] "miss:test")))

;; Records the names it was asked for, so "the chain asked for the right
;; secret" is observable rather than assumed.
(defn- watching-provider [asked name value]
  (reify provider/Provider
    (lookup [_ n] (swap! asked conj n) (when (= n name) value))
    (describe [_] "watching:test")))


;; ---------------------------------------------------------------------------
;; A LIVE client. Mode stays "live", the test feature is never activated,
;; so core/u-fetcher really does call system.fetch.
;; ---------------------------------------------------------------------------

(defn- live-sdk [stub & {:keys [apikey auth-nil secrets]}]
  (let [opts (vs/jm "base" BASE
                    "allow" (vs/jm "op" ALLOWOP)
                    "system" (vs/jm "fetch" (:fetch stub)))]
    (when apikey (.put ^java.util.Map opts "apikey" apikey))
    (when auth-nil (.put ^java.util.Map opts "auth" nil))
    (when secrets (.put ^java.util.Map opts "feature" (vs/jm "secrets" secrets)))
    (client/make-sdk opts)))


(defn- sekopts [& kvs]
  (apply vs/jm (concat ["active" true] kvs)))


(defn- feature-of [sdk name]
  (first (filter (fn [f] (= name (core/feature-get-name f)))
                 (deref (core/client-features sdk)))))


;; The Authorization header carries the SPEC's credential prefix, which a
;; TEMPLATE cannot know: an OpenAPI `http`/`bearer` scheme gives
;; `Bearer <token>`, an apiKey scheme the raw token. So assert on the
;; CREDENTIAL and let the prefix be whatever this SDK's API declares.
(defn- credential-is [got token msg]
  (let [s (str (or got ""))]
    (t/is-true (or (= s token) (str/ends-with? s (str " " token)))
               (str msg ": expected the authorization header to carry " token
                    ", got " (pr-str got)))))


;; ---------------------------------------------------------------------------
;; THE ENTITY PATH. Reached through the client utility view, exactly as
;; sdk.test.pipeline and sdk.test.feature reach it, because a TEMPLATE
;; cannot name this API's entities. The transport crossing is core's own:
;; u-make-request calls (uget ctx :fetcher) - the same slot, the same
;; wrapper, the same fetchdef - and u-done raises the SDK error the way a
;; generated op does.
;; ---------------------------------------------------------------------------

(defn- entity-op [sdk opname]
  (let [rootctx (core/client-root-ctx sdk)
        ctx (core/make-context
             (vs/jm "opname" opname "entity" {:get-name (fn [] "widget")})
             rootctx)
        opts (core/client-options-map sdk)
        gstr (fn [k] (let [v (vs/getprop opts k)] (if (string? v) v "")))
        spec (core/make-spec (vs/jm "base" (gstr "base") "prefix" (gstr "prefix")
                                    "suffix" (gstr "suffix") "path" "/widget"
                                    "method" "GET" "params" (vs/jm) "query" (vs/jm)
                                    "headers" ((core/uget ctx :prepare-headers) ctx)
                                    "step" "start"))]
    (core/oset! ctx :spec spec)
    (try
      (let [[_ aerr] ((core/uget ctx :prepare-auth) ctx)]
        (when aerr (core/sdk-throw aerr)))
      (let [[_ rerr] ((core/uget ctx :make-request) ctx)]
        (when rerr (core/sdk-throw rerr)))
      (let [[_ perr] ((core/uget ctx :make-response) ctx)]
        (when perr (core/sdk-throw perr)))
      (let [[_ merr] ((core/uget ctx :make-result) ctx)]
        (when merr (core/sdk-throw merr)))
      {:ok true :data ((core/uget ctx :done) ctx)}
      (catch clojure.lang.ExceptionInfo e
        {:ok false :err (core/ex->sdk e) :msg (.getMessage e)}))))


;; ---------------------------------------------------------------------------

(defn run [rec]
  (letfn [(chk [name thunk] (t/run-check rec name thunk))]

    ;; ---- INACTIVE COSTS NOTHING ----

    (chk "secrets-inactive-apikey-unchanged"
         (fn []
           (let [stub (counting-fetch)
                 sdk (live-sdk stub :apikey "OPTKEY01")
                 res (client/direct sdk (vs/jm "path" "/thing"))]
             (t/is-true (= true (vs/getprop res "ok")) (str "direct failed: " (brief res)))
             (t/is-eq (sent stub) 1 "one request")
             (credential-is (:auth (call-at stub 0)) "OPTKEY01" "inactive")
             ;; No feature, no instance.
             (t/is-nil (feature-of sdk "secrets") "no secrets feature installed"))))

    (chk "secrets-inactive-no-apikey-no-header"
         (fn []
           (let [stub (counting-fetch)
                 sdk (live-sdk stub)]
             (client/direct sdk (vs/jm "path" "/thing"))
             (t/is-eq (sent stub) 1 "one request")
             (t/is-nil (:auth (call-at stub 0)) "no authorization header"))))

    ;; ---- apikey KEEPS ITS MEANING ----

    (chk "secrets-apikey-option-wins-on-the-wire"
         (fn []
           (let [stub (counting-fetch)
                 sdk (live-sdk stub :apikey "OPTKEY01"
                               :secrets (sekopts "providers"
                                                 (vs/jt (fixed-provider "apikey" "CHAINKEY01"))))
                 res (client/direct sdk (vs/jm "path" "/thing"))]
             (t/is-true (= true (vs/getprop res "ok")) (str "direct failed: " (brief res)))
             (t/is-eq (sent stub) 1 "one request")
             (credential-is (:auth (call-at stub 0)) "OPTKEY01" "apikey wins")
             ;; The explicit option is a REAL STORE, not a special case: a
             ;; directed read names it like any other provider.
             ;; Reached through the feature's own public accessor, which is
             ;; the clojure spelling of ts's sdk.secrets().
             (let [f (secrets/of sdk)]
               (t/is-some f "secrets feature installed")
               (t/is-eq (sekreto/getfrom (secrets/sek f) "options" "apikey")
                        "OPTKEY01" "directed read of the options store")))))

    (chk "secrets-omitted-apikey-defers-to-the-chain"
         (fn []
           (let [stub (counting-fetch)
                 sdk (live-sdk stub :secrets (sekopts "providers"
                                                      (vs/jt (fixed-provider "apikey" "CHAINKEY01"))))
                 f (feature-of sdk "secrets")]
             (t/is-some f "secrets feature installed")
             ;; Nothing is resolved before the first operation: init builds
             ;; the chain and never looks anything up.
             (t/is-eq (secrets/credential f) "" "unresolved before the first op")
             (client/direct sdk (vs/jm "path" "/thing"))
             (t/is-eq (sent stub) 1 "one request")
             (credential-is (:auth (call-at stub 0)) "CHAINKEY01" "chain")
             (t/is-eq (secrets/credential f) "CHAINKEY01" "held in feature state")
             ;; THE SHARED OPTIONS MAP IS NEVER WRITTEN.
             (t/is-eq (vs/getprop (client/options-map sdk) "apikey") ""
                      "the options map is untouched"))))

    (chk "secrets-custom-provider-is-asked-for-the-right-name"
         (fn []
           (let [asked (atom [])
                 stub (counting-fetch)
                 sdk (live-sdk stub :secrets (sekopts "providers"
                                                      (vs/jt (watching-provider asked "apikey" "CUSTOM01"))))]
             (client/direct sdk (vs/jm "path" "/thing"))
             (credential-is (:auth (call-at stub 0)) "CUSTOM01" "custom provider")
             (t/is-deep (vec @asked) ["apikey"] "asked for the configured secret name"))))

    (chk "secrets-a-miss-everywhere-sends-unauthenticated"
         (fn []
           (let [stub (counting-fetch)
                 sdk (live-sdk stub :secrets (sekopts "providers" (vs/jt (miss-provider))))]
             (client/direct sdk (vs/jm "path" "/thing"))
             (t/is-eq (sent stub) 1 "the request still goes out")
             (t/is-nil (:auth (call-at stub 0)) "no authorization header"))))

    ;; ---- FAIL CLOSED: a provider ERROR is not a miss ----
    ;;
    ;; direct() and graphql() run NO feature hooks at all. They are covered
    ;; because resolution lives at the TRANSPORT, which every wire path
    ;; crosses - which is the whole reason it lives there.

    (chk "secrets-provider-error-fails-direct-rather-than-sending"
         (fn []
           (let [stub (counting-fetch)
                 sdk (live-sdk stub :secrets (sekopts "providers"
                                                      (vs/jt (broken-provider "vault unreachable"))))
                 res (client/direct sdk (vs/jm "path" "/thing"))]
             (t/is-eq (sent stub) 0
                      (str "a request must not go out unauthenticated because a"
                           " provider broke, but one reached the transport: " (wire stub)))
             (t/is-eq (vs/getprop res "ok") false (str "expected a failure, got " (brief res)))
             (let [err (vs/getprop res "err")]
               (t/is-eq (core/err-code err) "secrets_provider" "error code")
               (t/is-true (str/includes? (core/err-msg err) "vault unreachable")
                          (str "expected the provider's own message, got "
                               (pr-str (core/err-msg err)))))

             ;; CONTROL, which makes that zero mean REFUSED rather than
             ;; UNWIRED: the same construction with a WORKING provider must
             ;; reach the same transport, once, carrying the credential.
             (let [control (counting-fetch)
                   ok (client/direct
                       (live-sdk control :secrets (sekopts "providers"
                                                           (vs/jt (fixed-provider "apikey" "RAWKEY01"))))
                       (vs/jm "path" "/thing"))]
               (t/is-eq (vs/getprop ok "ok") true (str "the control request failed: " (brief ok)))
               (t/is-eq (sent control) 1
                        "the control request never reached system.fetch, so this test cannot observe a request going out at all")
               (credential-is (:auth (call-at control 0)) "RAWKEY01" "control")))))

    (chk "secrets-provider-error-fails-graphql-rather-than-sending"
         (fn []
           (let [stub (counting-fetch)
                 sdk (live-sdk stub :secrets (sekopts "providers"
                                                      (vs/jt (broken-provider "vault unreachable"))))
                 res (client/graphql sdk "{ thing }" nil)]
             (t/is-eq (sent stub) 0
                      (str "a graphql request must not go out unauthenticated,"
                           " but one reached the transport: " (wire stub)))
             (t/is-eq (vs/getprop res "ok") false (str "expected a failure, got " (brief res)))
             (t/is-true (str/includes? (core/err-msg (vs/getprop res "err")) "vault unreachable")
                        "the provider's own message")

             (let [control (counting-fetch)
                   ok (client/graphql
                       (live-sdk control :secrets (sekopts "providers"
                                                           (vs/jt (fixed-provider "apikey" "RAWKEY01"))))
                       "{ thing }" nil)]
               (t/is-eq (vs/getprop ok "ok") true (str "the control request failed: " (brief ok)))
               (t/is-eq (sent control) 1
                        "the control graphql request never reached system.fetch")
               (credential-is (:auth (call-at control 0)) "RAWKEY01" "control")))))

    (chk "secrets-provider-error-fails-the-entity-path-rather-than-sending"
         (fn []
           (let [stub (counting-fetch)
                 sdk (live-sdk stub :secrets (sekopts "providers"
                                                      (vs/jt (broken-provider "vault unreachable"))))
                 res (entity-op sdk "load")]
             (t/is-eq (sent stub) 0
                      (str "an entity op must not go out unauthenticated: " (wire stub)))
             (t/is-eq (:ok res) false (str "expected the op to fail, got " (:msg res)))
             (t/is-true (str/includes? (str (:msg res)) "vault unreachable")
                        (str "expected the provider's own message, got " (pr-str (:msg res))))

             (let [control (counting-fetch)
                   ok (entity-op
                       (live-sdk control :secrets (sekopts "providers"
                                                           (vs/jt (fixed-provider "apikey" "RAWKEY01"))))
                       "load")]
               (t/is-eq (:ok ok) true (str "the control entity op failed: " (:msg ok)))
               (t/is-eq (sent control) 1
                        "the control entity op never reached system.fetch, so this test cannot observe a request going out at all")
               (credential-is (:auth (call-at control 0)) "RAWKEY01" "control")))))

    ;; A FAILED RESOLUTION IS NEVER CACHED. Holding one would mean a
    ;; transient vault outage poisoned the client permanently - every later
    ;; operation failing with the original error long after it recovered.
    (chk "secrets-a-failed-resolution-is-never-cached"
         (fn []
           (let [broken (atom true)
                 flaky (reify provider/Provider
                         (lookup [_ n]
                           (when @broken (throw (sekreto/sekretoerror "vault unreachable")))
                           (when (= n "apikey") "RECOVERED01"))
                         (describe [_] "flaky:test"))
                 stub (counting-fetch)
                 sdk (live-sdk stub :secrets (sekopts "providers" (vs/jt flaky)))]
             (t/is-eq (vs/getprop (client/direct sdk (vs/jm "path" "/thing")) "ok") false "first op fails")
             (t/is-eq (sent stub) 0 (str "nothing on the wire: " (wire stub)))
             (reset! broken false)
             (let [res (client/direct sdk (vs/jm "path" "/thing"))]
               (t/is-eq (vs/getprop res "ok") true (str "second op should recover: " (brief res)))
               (t/is-eq (sent stub) 1 "the recovered op reaches the wire")
               (credential-is (:auth (call-at stub 0)) "RECOVERED01" "recovered")))))

    ;; ---- DECLARATIVE SPECS, IN BOTH SPELLINGS ----
    ;;
    ;; The option pipeline delivers string-keyed struct maps; a caller may
    ;; also hand a Clojure keyword-keyed map straight in. sekreto reads a
    ;; spec with KEYWORD keys, so both have to arrive as one.

    (chk "secrets-accepts-a-struct-map-provider-spec"
         (fn []
           (let [stub (counting-fetch)
                 sdk (live-sdk stub :secrets
                               (sekopts "providers"
                                        (vs/jt (vs/jm "kind" "memory" "name" "local"
                                                      "values" (vs/jm "APIKEY" "MEMKEY01")))))]
             (client/direct sdk (vs/jm "path" "/thing"))
             (credential-is (:auth (call-at stub 0)) "MEMKEY01" "struct-map spec"))))

    ;; A KEYWORD-keyed spec does not survive option validation - it arrives
    ;; as {":kind" nil}, keys renamed and values dropped. That is refused at
    ;; the chain build and the transport gate REFUSES THE REQUEST: a
    ;; misconfigured chain must never degrade into an unauthenticated send,
    ;; and the message has to name the mistake rather than surface as
    ;; "unknown provider kind: " with an empty kind.
    (chk "secrets-a-keyword-keyed-spec-fails-closed-with-a-clear-message"
         (fn []
           (let [stub (counting-fetch)
                 sdk (live-sdk stub :secrets
                               (sekopts "providers"
                                        (vs/jt {:kind "memory" :name "local"
                                                :values {"APIKEY" "KWKEY01"}})))
                 res (client/direct sdk (vs/jm "path" "/thing"))]
             (t/is-eq (vs/getprop res "ok") false (str "expected a failure, got " (brief res)))
             (t/is-eq (sent stub) 0
                      (str "nothing may reach the wire on a broken chain: " (wire stub)))
             (t/is-true (str/includes? (core/err-msg (vs/getprop res "err"))
                                       "unusable provider chain entry")
                        (str "expected the chain-entry message, got "
                             (pr-str (core/err-msg (vs/getprop res "err"))))))))

    ;; ---- THE CACHE OPTION MEANS WHAT IT SAYS ----

    (chk "secrets-cache-true-asks-the-chain-once"
         (fn []
           (let [n (atom 0)
                 rotating (reify provider/Provider
                            (lookup [_ _] (str "ROT0" (swap! n inc)))
                            (describe [_] "rotating:test"))
                 stub (counting-fetch)
                 sdk (live-sdk stub :secrets (sekopts "providers" (vs/jt rotating)))]
             (client/direct sdk (vs/jm "path" "/thing"))
             (client/direct sdk (vs/jm "path" "/thing"))
             (t/is-eq (sent stub) 2 "two requests")
             (credential-is (:auth (call-at stub 0)) "ROT01" "first")
             (credential-is (:auth (call-at stub 1)) "ROT01" "cached"))))

    (chk "secrets-cache-false-asks-the-chain-every-request"
         (fn []
           (let [n (atom 0)
                 rotating (reify provider/Provider
                            (lookup [_ _] (str "ROT0" (swap! n inc)))
                            (describe [_] "rotating:test"))
                 stub (counting-fetch)
                 sdk (live-sdk stub :secrets (sekopts "cache" false
                                                      "providers" (vs/jt rotating)))]
             (client/direct sdk (vs/jm "path" "/thing"))
             (client/direct sdk (vs/jm "path" "/thing"))
             (t/is-eq (sent stub) 2 "two requests")
             (credential-is (:auth (call-at stub 0)) "ROT01" "first")
             (credential-is (:auth (call-at stub 1)) "ROT02" "asked again"))))

    ;; A MISS IS NOT A CACHEABLE ANSWER - sekreto's own rule, which this
    ;; feature used to override from the layer above. DEFAULT caching here,
    ;; which is the whole point: `cache: true` is about holding a HIT (the
    ;; test above pins that half), and keeping the settled resolution after
    ;; a miss meant the chain was never asked again for the life of the
    ;; client - a secret provisioned after startup was invisible forever.
    (chk "secrets-cache-true-re-asks-after-a-miss"
         (fn []
           (let [present (atom false)
                 n (atom 0)
                 late (reify provider/Provider
                        (lookup [_ _]
                          (swap! n inc)
                          (when @present "LATEKEY01"))
                        (describe [_] "late:test"))
                 stub (counting-fetch)
                 sdk (live-sdk stub :secrets (sekopts "providers" (vs/jt late)))]
             (client/direct sdk (vs/jm "path" "/thing"))
             (t/is-nil (:auth (call-at stub 0))
                       "the chain has nothing yet, so no credential should go out")
             (let [asked @n]
               (reset! present true)
               (client/direct sdk (vs/jm "path" "/thing"))
               (t/is-eq (< asked @n) true
                        "the MISS was cached: a secret that appears later can never be picked up")
               (credential-is (:auth (call-at stub 1)) "LATEKEY01" "late secret")))))

    ;; ---- auth: nil SUPPRESSES, chain or no chain ----

    (chk "secrets-auth-nil-suppresses-the-credential"
         (fn []
           (let [stub (counting-fetch)
                 sdk (live-sdk stub :apikey "OPTKEY01" :auth-nil true
                               :secrets (sekopts "providers"
                                                 (vs/jt (fixed-provider "apikey" "CHAINKEY01"))))]
             (client/direct sdk (vs/jm "path" "/thing"))
             (t/is-eq (sent stub) 1 "the request still goes out")
             (t/is-nil (:auth (call-at stub 0))
                       "nothing on the wire, even though the chain resolved")
             ;; The suppression SURVIVES option validation rather than being
             ;; replaced by the optspec's default auth map.
             (t/is-nil (vs/getprop (client/options-map sdk) "auth")
                       "options.auth is a present null"))))

    ;; ---- THE ACCESS-TOKEN EXCHANGE ----

    (let [tokenpath "auth/token"
          tokenurl (str BASE "/" tokenpath)
          xopts (fn [] (vs/jm "active" true "path" tokenpath "method" "POST"
                              "request" "refresh_token" "response" "access_token"
                              "statuses" (vs/jt 401) "retries" 1))
          xsecrets (fn [] (sekopts "name" "refresh_token"
                                   "providers" (vs/jt (fixed-provider "refresh_token" "REFRESH01"))
                                   "exchange" (xopts)))]

      (chk "secrets-exchange-buys-a-token-and-retries-a-spent-one"
           (fn []
             (let [issued (atom 0)
                   apicalls (atom 0)
                   stub (counting-fetch
                         (fn [_n url _fd]
                           (if (str/ends-with? url tokenpath)
                             [(response 200 (vs/jm "access_token"
                                                   (str "ACCESS0" (swap! issued inc)))) nil]
                             (if (= 1 (swap! apicalls inc))
                               [(response 401 (vs/jm "err" "expired")) nil]
                               [(response 200 (vs/jm "ok" true)) nil]))))
                   sdk (live-sdk stub :secrets (xsecrets))
                   res (client/direct sdk (vs/jm "path" "/thing"))]
               (t/is-eq (vs/getprop res "ok") true (str "direct failed: " (brief res)))
               (t/is-eq (sent stub) 4 (str "token, 401, token, retry: " (wire stub)))
               (t/is-eq @issued 2 "two tokens issued")

               ;; The token endpoint is base + '/' + exchange.path, and the
               ;; refresh credential is MARSHALLED into the body.
               (let [buy (call-at stub 0)]
                 (t/is-eq (:url buy) tokenurl "token endpoint URL")
                 (t/is-eq (:method buy) "POST" "token endpoint method")
                 (t/is-eq (vs/getprop (core/json-parse (str (:body buy))) "refresh_token")
                          "REFRESH01" "marshalled refresh token"))

               (credential-is (:auth (call-at stub 1)) "ACCESS01" "attempt 1")
               (credential-is (:auth (call-at stub 3)) "ACCESS02" "the retry"))))

      (chk "secrets-exchange-with-auth-nil-never-buys-or-retries"
           (fn []
             (let [stub (counting-fetch
                         (fn [_n url _fd]
                           (if (str/ends-with? url tokenpath)
                             [(response 200 (vs/jm "access_token" "ACCESS01")) nil]
                             [(response 401 (vs/jm "err" "expired")) nil])))
                   sdk (live-sdk stub :auth-nil true :secrets (xsecrets))]
               (client/direct sdk (vs/jm "path" "/thing"))
               ;; NOTHING IS BOUGHT, and the API request goes out ONCE.
               ;;
               ;; This used to read "token + one API call only": the token
               ;; WAS bought at resolution, because resolve! ran before
               ;; with-refresh's suppression check. A purchase is a
               ;; credential-bearing call - the refresh token travels to the
               ;; token endpoint in the request body - so `auth: nil` was
               ;; only ever half-held, and stopping the retry could not
               ;; unsend it. The suppression is now honoured before the
               ;; first purchase.
               (t/is-eq (sent stub) 1 (str "one API call, no purchase: " (wire stub)))
               (t/is-nil (:auth (call-at stub 0)) "no authorization header"))))

      (chk "secrets-exchange-with-no-refresh-token-fails-closed"
           (fn []
             (let [stub (counting-fetch)
                   sdk (live-sdk stub :secrets (sekopts "name" "refresh_token"
                                                        "providers" (vs/jt (miss-provider))
                                                        "exchange" (xopts)))
                   res (client/direct sdk (vs/jm "path" "/thing"))]
               (t/is-eq (vs/getprop res "ok") false (str "expected a failure, got " (brief res)))
               (t/is-eq (sent stub) 0
                        (str "nothing may reach the wire without a credential: " (wire stub)))
               (t/is-true (str/includes? (core/err-msg (vs/getprop res "err")) "no refresh token")
                          "the missing-refresh-token message")))))))
