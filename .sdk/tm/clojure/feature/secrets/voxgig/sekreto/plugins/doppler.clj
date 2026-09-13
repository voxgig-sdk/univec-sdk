;; VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (clojure/plugins/voxgig/sekreto/plugins/doppler.clj)
;; Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
;; Doppler, as a voxgig/plugin definition.
;;
;; A plugin rather than a built-in kind because it opens a socket
;; (docs/design/plugin-providers.md).
;;
;; A port of typescript/plugins/doppler.ts, which is canonical.

(ns voxgig.sekreto.plugins.doppler
  (:require [voxgig.sekreto.core :as core]
            [voxgig.sekreto.addr :refer [checkaddr]]
            [voxgig.sekreto.json :as json]
            [voxgig.sekreto.provider :as provider]
            [voxgig.sekreto.providers :as providers]
            [voxgig.sekreto.plugins.httpjson :as http]))

(defrecord Doppler [token project config addr values]
  provider/Provider

  ;; Doppler.
  ;;
  ;; The whole config is downloaded once - Doppler's own bulk endpoint - and
  ;; answered from memory, like a remote .env: `api.token` is the
  ;; `API_TOKEN` entry. A service token is config-scoped, so project and
  ;; config are only needed with broader tokens.
  (lookup [_ name]
    (let [loaded (or @values
                     (reset! values
                             (let [useaddr (http/trimslash (http/firstof addr "https://api.doppler.com"))
                                   _ (checkaddr useaddr)
                                   url (cond-> (str useaddr
                                                    "/v3/configs/config/secrets/download?format=json")
                                         (core/notempty project)
                                         (str "&project=" (http/uriescape project))

                                         (core/notempty config)
                                         (str "&config=" (http/uriescape config)))
                                   res (http/fetchjson "GET" url
                                                  {"authorization" (str "Bearer " (or token ""))})
                                   body (json/asobj (:body res))]

                               (when (or (not= 200 (:status res)) (nil? body))
                                 (throw (core/sekretoerror
                                         (str "sekreto: doppler error: " (:status res)))))

                               (json/omap (keep (fn [[key value]]
                                                  (when-let [text (json/astext value)] [key text]))
                                                body)))))]
      (get loaded (core/envkey name))))

  (describe [_]
    (str "doppler" (when (core/notempty project) (str ":" project "/" (or config ""))))))

(def doppler
  "The `doppler` provider kind."
  (providers/providerplugin
   "doppler"
   (fn [{:keys [token project config addr]}]
     (->Doppler token project config addr (atom nil)))))
