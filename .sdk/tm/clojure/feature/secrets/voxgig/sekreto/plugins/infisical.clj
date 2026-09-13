;; VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (clojure/plugins/voxgig/sekreto/plugins/infisical.clj)
;; Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
;; Infisical, as a voxgig/plugin definition.
;;
;; A plugin rather than a built-in kind because it opens a socket
;; (docs/design/plugin-providers.md).
;;
;; A port of typescript/plugins/infisical.ts, which is canonical.

(ns voxgig.sekreto.plugins.infisical
  (:require [voxgig.sekreto.core :as core]
            [voxgig.sekreto.addr :refer [checkaddr]]
            [voxgig.sekreto.json :as json]
            [voxgig.sekreto.provider :as provider]
            [voxgig.sekreto.providers :as providers]
            [voxgig.sekreto.plugins.httpjson :as http]))

(defrecord Infisical [addr token clientid clientsecret project environment path state]
  provider/Provider

  ;; Infisical.
  ;;
  ;; `api.token` reads the secret keyed `API_TOKEN` (Infisical's own
  ;; convention is environment-style keys) at a secret path in one
  ;; environment of a project. Auth is a token, or a universal-auth (machine
  ;; identity) login with clientid/clientsecret.
  (lookup [_ name]
    (let [useaddr (http/trimslash (http/firstof addr "https://app.infisical.com"))
          _ (checkaddr useaddr)

          _ (when (or (= "" (or project "")) (= "" (or environment "")))
              (throw (core/sekretoerror "sekreto: infisical: no project/environment")))

          login (fn []
                  (if (core/notempty token)
                    [token Long/MAX_VALUE]
                    (do
                      (when (or (nil? (core/notempty clientid))
                                (nil? (core/notempty clientsecret)))
                        (throw (core/sekretoerror
                                "sekreto: infisical: no token and no client credentials")))

                      (let [body (json/omap [["clientId" clientid] ["clientSecret" clientsecret]])
                            res (http/fetchjson "POST"
                                           (str useaddr "/api/v1/auth/universal-auth/login")
                                           {"content-type" "application/json"}
                                           (json/stringify body))
                            got (json/astext (json/dig (:body res) "accessToken"))]

                        (when (or (not= 200 (:status res)) (nil? (core/notempty got)))
                          (throw (core/sekretoerror
                                  (str "sekreto: infisical login failed: " (:status res)))))

                        [got (http/renewtime (json/dig (:body res) "expiresIn"))]))))

          live (http/withtoken state login)
          url (str useaddr "/api/v3/secrets/raw/" (core/envkey name)
                   "?workspaceId=" (http/uriescape project)
                   "&environment=" (http/uriescape environment)
                   "&secretPath=" (http/uriescape (http/firstof path "/")))
          res (http/fetchjson "GET" url {"authorization" (str "Bearer " (or live ""))})]

      (cond
        (= 404 (:status res)) nil

        (not= 200 (:status res))
        (throw (core/sekretoerror (str "sekreto: infisical error: " (:status res))))

        :else (json/astext (json/dig (:body res) "secret" "secretValue")))))

  (describe [_] (str "infisical:" (or project "") "/" (or environment ""))))

(def infisical
  "The `infisical` provider kind."
  (providers/providerplugin
   "infisical"
   (fn [{:keys [addr token clientid clientsecret project environment path]}]
     (->Infisical addr token clientid clientsecret project environment path
                  (atom {:token nil :renewat Long/MAX_VALUE})))))
