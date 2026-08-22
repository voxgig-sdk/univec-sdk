;; Univec SDK primary utility tests — the utility object exposes every
;; pipeline member and the vendored struct library, and a few core behaviours.
(ns sdk.test.primary
  (:require [sdk.core :as core]
            [sdk.client :as client]
            [sdk.testutil :as t]
            [voxgig.struct :as vs]
            [clojure.string :as str]))

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
