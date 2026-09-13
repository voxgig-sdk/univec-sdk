;; VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (clojure/plugins/voxgig/sekreto/plugins/onepassword.clj)
;; Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
;; 1Password through a Connect server, as a voxgig/plugin definition.
;;
;; A plugin rather than a built-in kind because it opens a socket
;; (docs/design/plugin-providers.md).
;;
;; A port of typescript/plugins/onepassword.ts, which is canonical.

(ns voxgig.sekreto.plugins.onepassword
  (:require [voxgig.sekreto.core :as core]
            [voxgig.sekreto.addr :refer [checkaddr]]
            [voxgig.sekreto.json :as json]
            [voxgig.sekreto.provider :as provider]
            [voxgig.sekreto.providers :as providers]
            [voxgig.sekreto.plugins.httpjson :as http]))

(defrecord Onepassword [addr token vault vaultid]
  provider/Provider

  ;; 1Password, through a Connect server.
  ;;
  ;; The item titled `api.token` (titles keep their dots), in the named
  ;; vault. The value is the field with purpose PASSWORD, or the field
  ;; labelled `value`. A vault that cannot be found is an error - config
  ;; names it, so its absence is a broken store, not a missing secret.
  (lookup [_ name]
    (core/checkname name)

    (let [useaddr (http/trimslash (or addr ""))
          _ (when (= "" useaddr)
              (throw (core/sekretoerror "sekreto: onepassword: no addr")))
          _ (checkaddr useaddr)

          auth {"authorization" (str "Bearer " (or token ""))}

          id (or @vaultid
                 (reset! vaultid
                         (let [want (or vault "")]
                           (when (= "" want)
                             (throw (core/sekretoerror "sekreto: onepassword: no vault")))

                           (let [res (http/fetchjson "GET" (str useaddr "/v1/vaults") auth)
                                 list (json/asarr (:body res))]
                             (when (or (not= 200 (:status res)) (nil? list))
                               (throw (core/sekretoerror
                                       (str "sekreto: onepassword error: " (:status res)
                                            ": listing vaults"))))

                             (let [found (some (fn [entry]
                                                 (when (or (= want (json/astext (json/dig entry "id")))
                                                           (= want (json/astext (json/dig entry "name"))))
                                                   entry))
                                               list)]
                               (when (nil? found)
                                 (throw (core/sekretoerror
                                         (str "sekreto: onepassword: no vault named " want))))

                               (or (json/astext (json/dig found "id")) ""))))))

          filter (http/uriescape (str "title eq \"" name "\""))
          found (http/fetchjson "GET" (str useaddr "/v1/vaults/" id "/items?filter=" filter) auth)
          items (json/asarr (:body found))]

      (when (or (not= 200 (:status found)) (nil? items))
        (throw (core/sekretoerror
                (str "sekreto: onepassword error: " (:status found) ": finding " name))))

      (when (seq items)
        (let [itemid (or (json/astext (json/dig (first items) "id")) "")
              item (http/fetchjson "GET" (str useaddr "/v1/vaults/" id "/items/" itemid) auth)]

          (when (not= 200 (:status item))
            (throw (core/sekretoerror
                    (str "sekreto: onepassword error: " (:status item) ": reading " name))))

          (let [fields (or (json/asarr (json/dig (:body item) "fields")) [])
                pick (fn [key want]
                       (some (fn [field]
                               (when (= want (json/asstr (json/dig field key))) field))
                             fields))]
            (json/astext (json/dig (or (pick "purpose" "PASSWORD") (pick "label" "value"))
                                   "value")))))))

  (describe [_] (str "onepassword:" (or vault ""))))

(def onepassword
  "The `onepassword` provider kind."
  (providers/providerplugin
   "onepassword"
   (fn [{:keys [addr token vault]}]
     (->Onepassword addr token vault (atom nil)))))
