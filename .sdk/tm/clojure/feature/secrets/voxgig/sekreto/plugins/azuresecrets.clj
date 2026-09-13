;; VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (clojure/plugins/voxgig/sekreto/plugins/azuresecrets.clj)
;; Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
;; Azure Key Vault, as a voxgig/plugin definition.
;;
;; A plugin rather than a built-in kind because it opens a socket
;; (docs/design/plugin-providers.md).
;;
;; A port of typescript/plugins/azuresecrets.ts, which is canonical.

(ns voxgig.sekreto.plugins.azuresecrets
  (:require [clojure.string :as string]
            [voxgig.sekreto.core :as core]
            [voxgig.sekreto.addr :refer [checkaddr]]
            [voxgig.sekreto.json :as json]
            [voxgig.sekreto.provider :as provider]
            [voxgig.sekreto.providers :as providers]
            [voxgig.sekreto.plugins.httpjson :as http]))

;; The Key Vault audience an Azure token is minted for.
(def ^:private RESOURCE "https://vault.azure.net")

(defrecord Azuresecrets [vault token tenant clientid clientsecret
                         loginaddr imdsaddr apiversion state]
  provider/Provider

  ;; Azure Key Vault.
  ;;
  ;; `api.token` reads secret `api-token` (dots flattened to `-`; Key Vault
  ;; names allow nothing else), current version. The token comes from
  ;; config, then a client-credentials login when tenant/clientid/
  ;; clientsecret are given, then the IMDS managed-identity endpoint - so on
  ;; Azure's own platform no credential configuration is needed.
  ;;
  ;; As with GCP, the IMDS call is plain http to a link-local host by
  ;; platform design and carries no credential; the login and vault
  ;; addresses are `checkaddr`-guarded.
  (lookup [_ name]
    (when (= "" (or vault ""))
      (throw (core/sekretoerror "sekreto: azure: no vault")))

    ;; Only an explicit scheme is a URL; a vault NAMED httpvault must still
    ;; become https://httpvault.vault.azure.net.
    (let [vaulturl (if (or (string/starts-with? vault "http://")
                           (string/starts-with? vault "https://"))
                     vault
                     (str "https://" vault ".vault.azure.net"))
          _ (checkaddr vaulturl)

          login (fn []
                  (cond
                    (core/notempty token) [token Long/MAX_VALUE]

                    (and (core/notempty tenant)
                         (core/notempty clientid)
                         (core/notempty clientsecret))
                    (let [useloginaddr (http/firstof loginaddr "https://login.microsoftonline.com")
                          _ (checkaddr useloginaddr)
                          url (str (http/trimslash useloginaddr) "/" tenant "/oauth2/v2.0/token")
                          form (str "grant_type=client_credentials"
                                    "&client_id=" (http/uriescape clientid)
                                    "&client_secret=" (http/uriescape clientsecret)
                                    "&scope=" (http/uriescape (str RESOURCE "/.default")))
                          res (http/fetchjson "POST" url
                                         {"content-type" "application/x-www-form-urlencoded"}
                                         form)
                          got (json/astext (json/dig (:body res) "access_token"))]

                      (when (or (not= 200 (:status res)) (nil? (core/notempty got)))
                        (throw (core/sekretoerror
                                (str "sekreto: azure login failed: " (:status res)))))

                      [got (http/renewtime (json/dig (:body res) "expires_in"))])

                    :else
                    (let [imds (str (http/trimslash (http/firstof imdsaddr "http://169.254.169.254"))
                                    "/metadata/identity/oauth2/token?api-version=2018-02-01"
                                    "&resource=" (http/uriescape RESOURCE))
                          res (http/fetchjson "GET" imds {"Metadata" "true"})
                          got (json/astext (json/dig (:body res) "access_token"))]

                      (when (or (not= 200 (:status res)) (nil? (core/notempty got)))
                        (throw (core/sekretoerror
                                (str "sekreto: azure: no token, no client credentials,"
                                     " and IMDS did not answer"))))

                      [got (http/renewtime (json/dig (:body res) "expires_in"))])))

          live (http/withtoken state login)
          url (str (http/trimslash vaulturl) "/secrets/" (core/flatname name "-")
                   "?api-version=" (http/firstof apiversion "7.4"))
          res (http/fetchjson "GET" url {"authorization" (str "Bearer " (or live ""))})]

      (cond
        (= 404 (:status res)) nil

        (not= 200 (:status res))
        (throw (core/sekretoerror (str "sekreto: azure error: " (:status res) ": " (http/bare url))))

        :else (json/astext (json/dig (:body res) "value")))))

  (describe [_] (str "azuresecrets:" (or vault ""))))

(def azuresecrets
  "The `azuresecrets` provider kind."
  (providers/providerplugin
   "azuresecrets"
   (fn [{:keys [vault token tenant clientid clientsecret loginaddr imdsaddr apiversion]}]
     (->Azuresecrets vault token tenant clientid clientsecret
                     loginaddr imdsaddr apiversion
                     (atom {:token nil :renewat Long/MAX_VALUE})))))
