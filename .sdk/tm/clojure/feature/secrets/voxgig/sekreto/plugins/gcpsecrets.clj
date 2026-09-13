;; VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (clojure/plugins/voxgig/sekreto/plugins/gcpsecrets.clj)
;; Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
;; GCP Secret Manager, as a voxgig/plugin definition.
;;
;; A plugin rather than a built-in kind because it opens a socket
;; (docs/design/plugin-providers.md).
;;
;; A port of typescript/plugins/gcpsecrets.ts, which is canonical.

(ns voxgig.sekreto.plugins.gcpsecrets
  (:require [voxgig.sekreto.core :as core]
            [voxgig.sekreto.addr :refer [checkaddr]]
            [voxgig.sekreto.json :as json]
            [voxgig.sekreto.provider :as provider]
            [voxgig.sekreto.providers :as providers]
            [voxgig.sekreto.plugins.httpjson :as http])
  (:import [java.nio.charset StandardCharsets]
           [java.util Base64]))

(defrecord Gcpsecrets [project token addr metadataaddr state]
  provider/Provider

  ;; GCP Secret Manager.
  ;;
  ;; `api.token` reads secret `api_token` (dots flattened to `_`; Secret
  ;; Manager ids have no hierarchy and reject dots), latest version. The
  ;; token comes from config, then `GOOGLE_OAUTH_ACCESS_TOKEN`, then the
  ;; GCE/GKE metadata server - so on Google's own platform no credential
  ;; configuration is needed at all.
  ;;
  ;; The metadata call itself is plain http to a link-local host by platform
  ;; design; no credential rides on it, so `checkaddr` guards the Secret
  ;; Manager address instead.
  (lookup [_ name]
    (when (= "" (or project ""))
      (throw (core/sekretoerror "sekreto: gcp: no project")))

    (let [useaddr (http/firstof addr "https://secretmanager.googleapis.com")
          _ (checkaddr useaddr)

          login (fn []
                  (let [configured (http/firstof token (core/getenv "GOOGLE_OAUTH_ACCESS_TOKEN"))]
                    (if (not= "" configured)
                      [configured Long/MAX_VALUE]
                      (let [host (or (core/notempty metadataaddr)
                                     (when-let [named (core/notempty (core/getenv "GCE_METADATA_HOST"))]
                                       (str "http://" named))
                                     "http://metadata.google.internal")
                            url (str (http/trimslash host)
                                     "/computeMetadata/v1/instance/service-accounts/default/token")
                            res (http/fetchjson "GET" url {"Metadata-Flavor" "Google"})
                            got (json/astext (json/dig (:body res) "access_token"))]

                        (when (or (not= 200 (:status res)) (nil? (core/notempty got)))
                          (throw (core/sekretoerror
                                  "sekreto: gcp: no token and metadata server did not answer")))

                        [got (http/renewtime (json/dig (:body res) "expires_in"))]))))

          live (http/withtoken state login)
          url (str (http/trimslash useaddr) "/v1/projects/" project "/secrets/"
                   (core/flatname name "_") "/versions/latest:access")
          res (http/fetchjson "GET" url {"authorization" (str "Bearer " (or live ""))})]

      (cond
        (= 404 (:status res)) nil

        (not= 200 (:status res))
        (throw (core/sekretoerror (str "sekreto: gcp error: " (:status res) ": " url)))

        :else
        (when-let [data (json/asstr (json/dig (:body res) "payload" "data"))]
          (try
            (String. (.decode (Base64/getDecoder) ^String data) StandardCharsets/UTF_8)
            ;; See the aws provider: an undecodable payload is an error.
            (catch IllegalArgumentException _
              (throw (core/sekretoerror "sekreto: gcp: undecodable secret"))))))))

  (describe [_] (str "gcpsecrets:" (or project ""))))

(def gcpsecrets
  "The `gcpsecrets` provider kind."
  (providers/providerplugin
   "gcpsecrets"
   (fn [{:keys [project token addr metadataaddr]}]
     (->Gcpsecrets project token addr metadataaddr
                   (atom {:token nil :renewat Long/MAX_VALUE})))))
