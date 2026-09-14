;; VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (clojure/plugins/voxgig/sekreto/plugins/hashicorp.clj)
;; Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
;; HashiCorp Vault, as a voxgig/plugin definition.
;;
;; A plugin rather than a built-in kind because it opens a socket: a chain
;; that names `hashicorp` must be handed this definition by the calling
;; project (docs/design/plugin-providers.md).
;;
;; A port of typescript/plugins/hashicorp.ts, which is canonical.

(ns voxgig.sekreto.plugins.hashicorp
  (:require [clojure.string :as string]
            [voxgig.sekreto.core :as core]
            [voxgig.sekreto.addr :refer [checkaddr]]
            [voxgig.sekreto.json :as json]
            [voxgig.sekreto.provider :as provider]
            [voxgig.sekreto.providers :as providers]
            [voxgig.sekreto.plugins.httpjson :as http]))

(defrecord Hashicorp [addr token mount kv vaultnamespace auth state]
  provider/Provider

  ;; HashiCorp Vault.
  ;;
  ;; KV v2 (the default): `api.token` reads `{addr}/v1/{mount}/data/api` and
  ;; takes the `token` field of `data.data`. KV v1 (`kv: 1`) reads
  ;; `{addr}/v1/{mount}/api` and takes the field of `data`. A 404 means "not
  ;; here" - a miss - so a vault can sit in a chain with fallbacks.
  ;;
  ;; A Vault Enterprise namespace rides the X-Vault-Namespace header, on
  ;; logins as well as reads.
  ;;
  ;; Instead of being handed a token, the provider can log in: Kubernetes
  ;; auth (the pod's service-account JWT, from its conventional path) or
  ;; AppRole. A failed login is an error, never a miss - it means this store
  ;; could not answer at all.
  (lookup [_ name]
    (checkaddr addr)

    (let [baseheaders (if (core/notempty vaultnamespace)
                        {"X-Vault-Namespace" vaultnamespace}
                        {})

          login (fn []
                  (when (nil? auth)
                    (throw (core/sekretoerror "sekreto: hashicorp: no token and no auth method")))

                  (let [method (:method auth)
                        url (str (http/trimslash addr) "/v1/auth/"
                                 (http/firstof (:mount auth) method) "/login")
                        body (case method
                               "kubernetes"
                               (let [file (or (core/notempty (:jwtfile auth))
                                              "/var/run/secrets/kubernetes.io/serviceaccount/token")
                                     jwt (or (core/notempty (:jwt auth))
                                             (core/notempty
                                              (some-> (providers/readfile (providers/path-of file) "hashicorp") string/trim))
                                             (throw (core/sekretoerror
                                                     (str "sekreto: hashicorp: cannot read jwt file "
                                                          file))))]
                                 (json/omap [["role" (or (:role auth) "")] ["jwt" jwt]]))

                               "approle"
                               (json/omap [["role_id" (or (:roleid auth) "")]
                                           ["secret_id" (or (:secretid auth) "")]])

                               (throw (core/sekretoerror
                                       (str "sekreto: hashicorp: unknown auth method: " method))))

                        res (http/fetchjson "POST" url baseheaders (json/stringify body))
                        got (json/astext (json/dig (:body res) "auth" "client_token"))]

                    (when (or (not= 200 (:status res)) (nil? (core/notempty got)))
                      (throw (core/sekretoerror
                              (str "sekreto: hashicorp login failed: " (:status res) ": " url))))

                    [got (http/renewtime (json/dig (:body res) "auth" "lease_duration"))]))

          live (http/withtoken state login)
          ref (core/vaultref name)
          base (str (http/trimslash addr) "/v1/" mount)
          url (if (= 1 kv)
                (str base "/" (:path ref))
                (str base "/data/" (:path ref)))

          res (http/fetchjson "GET" url (assoc baseheaders "X-Vault-Token" (or live "")))]

      (cond
        (= 404 (:status res)) nil

        (not= 200 (:status res))
        (throw (core/sekretoerror (str "sekreto: hashicorp error: " (:status res) ": " url)))

        :else
        (let [data (if (= 1 kv)
                     (json/dig (:body res) "data")
                     (json/dig (:body res) "data" "data"))]
          (json/astext (json/dig data (:field ref)))))))

  (describe [_] (str "hashicorp:" addr "/" mount)))

(def hashicorp
  "The `hashicorp` provider kind."
  (providers/providerplugin
   "hashicorp"
   (fn [{:keys [addr token mount kv vaultnamespace auth]}]
     (let [usekv (or kv 2)]
       ;; A version typo like kv: 3 must not quietly behave as v2 and turn
       ;; its 404s into misses; there is nothing safe to assume it meant.
       (when (and (not= 1 usekv) (not= 2 usekv))
         (throw (core/sekretoerror (str "sekreto: hashicorp: unsupported kv version: " usekv))))
       (->Hashicorp (or addr "") (core/notempty token) (or (core/notempty mount) "secret")
                    usekv vaultnamespace auth
                    (atom {:token (core/notempty token) :renewat Long/MAX_VALUE}))))))
