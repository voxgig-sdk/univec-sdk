;; VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (clojure/src/voxgig/sekreto.clj)
;; Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
;; sekreto: one interface for secrets, wherever they live.
;;
;; This is the namespace a consumer requires. THE CORE SURFACE: the chain,
;; the four built-in provider kinds, and the means of adding a fifth.
;;
;; The built-ins are the kinds that read at most a local file - env,
;; memory, dotenv, file. Everything that opens a socket, spawns a process
;; or signs a request is a PLUGIN, is not required by this namespace, and
;; is handed to a chain by the calling project:
;;
;;   (require '[voxgig.sekreto :as sekreto]
;;            '[voxgig.sekreto.plugins.hashicorp :refer [hashicorp]])
;;
;;   (def secrets
;;     (sekreto/sekreto [{:kind "env"}
;;                       {:kind "dotenv" :file ".env"}
;;                       {:kind "hashicorp" :addr vaultaddr :token vaulttoken}]
;;                      {:plugins [hashicorp]}))
;;
;;   (sekreto/get secrets "api.token")                  ; the chain answers
;;   (sekreto/getfrom secrets "hashicorp" "api.token")  ; one named store
;;
;; ...or, for every kind at once, `ALL` from `voxgig.sekreto.plugins`. See
;; docs/design/plugin-providers.md.
;;
;; Everything below this namespace is split by subject rather than by
;; audience: the names, the errors and the text helpers in
;; `voxgig.sekreto.core`, the address guard in `voxgig.sekreto.addr`, the
;; four built-in kinds and the plugin bridge in `voxgig.sekreto.providers`,
;; the chain itself in `voxgig.sekreto.chain`, and just enough JSON in
;; `voxgig.sekreto.json`.
;;
;; The split is not a matter of taste. The provider kinds need the name
;; helpers, so the namespace that defines those cannot be the one that
;; builds a chain out of kinds - a namespace cycle is a load error in
;; Clojure, not a warning. `carry` below republishes the parts as one API.

(ns voxgig.sekreto
  (:refer-clojure :exclude [get])
  (:require [voxgig.sekreto.addr :as addr]
            [voxgig.sekreto.chain :as chain]
            [voxgig.sekreto.core :as core]
            [voxgig.sekreto.providers :as providers]))

(defmacro ^:private carry
  "Republish another namespace's var here, under the same name and with its
  own docstring and argument lists, so that `doc` and every editor find them
  through this namespace."
  [source]
  `(doto (def ~(symbol (name source)) ~source)
     (alter-meta! merge (select-keys (meta (var ~source)) [:doc :arglists]))))

;; The names.
(carry core/validname)
(carry core/checkname)
(carry core/envkey)
(carry core/vaultref)
(carry core/flatname)
(carry core/awsparam)

;; The text helpers.
(carry core/parsedotenv)
(carry core/redact)

;; Errors: one type, asked about rather than caught by class.
(carry core/sekretoerror)
(carry core/sekretoerror?)

;; Refusing to send a credential in the clear. Every plugin that opens a
;; socket guards its address with this.
(carry addr/checkaddr)
(carry addr/safeaddr)

;; A chain, and the two ways to read it.
(carry chain/make)
(carry chain/get)
(carry chain/tryget)
(carry chain/getfrom)
(carry chain/tryfrom)
(carry chain/has)
(carry chain/hasin)
(carry chain/all)
(carry chain/sources)
(carry chain/stores)
(carry chain/storename)
(carry chain/redactall)
(carry chain/refresh)
(carry chain/close)

;; The four built-in kinds, and the one call that makes a fifth.
(carry providers/providerplugin)
(carry providers/BUILTINS)
(carry providers/KINDS)
(carry providers/PROVIDER-EXPORT)
(carry providers/ERROR-CODE)

(defn sekreto
  "A Sekreto from declarative provider specs - the same shape the shared
  spec and an app's config file use.

  Each spec is a map whose `:kind` picks the provider; `:name` gives the
  store name `getfrom` addresses, and defaults to the kind. `:plugins` in
  the options carries the provider kinds beyond the four built-ins that the
  chain may name, and `:cache false` turns the read cache off.

    (sekreto [{:kind \"memory\" :name \"local\" :values {\"API_TOKEN\" \"T\"}}
              {:kind \"hashicorp\" :addr addr :token token}]
             {:plugins [hashicorp]})"
  ([specs] (sekreto specs nil))
  ([specs opts] (chain/make specs opts)))
