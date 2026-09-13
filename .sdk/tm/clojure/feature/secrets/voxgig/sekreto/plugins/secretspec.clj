;; VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (clojure/plugins/voxgig/sekreto/plugins/secretspec.clj)
;; Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
;; SecretSpec, as a voxgig/plugin definition.
;;
;; A plugin rather than a built-in kind because it spawns a child process,
;; and a built-in kind reads at most a local file
;; (docs/design/plugin-providers.md).
;;
;; IT IS THE ONE PLUGIN THAT REACHES NO SOCKET, and it requires no HTTP
;; helper either: reaching `httpjson` for the one-line `reason` default
;; would load `java.net.http` into a process that only ever spawns a
;; child. The default is spelled out here instead, the way every other
;; port spells it.
;;
;; A port of typescript/plugins/secretspec.ts, which is canonical.

(ns voxgig.sekreto.plugins.secretspec
  (:require [clojure.string :as string]
            [voxgig.sekreto.core :as core]
            [voxgig.sekreto.provider :as provider]
            [voxgig.sekreto.providers :as providers]
            [voxgig.sekreto.plugins.proc :as proc]))

(defn secretspecmiss?
  "Does this SecretSpec failure mean \"no such secret\" rather than \"I
  could not answer\"?

  SecretSpec says `Secret 'API_TOKEN' not found` for both a name it does not
  declare and one declared with no value, and both are misses: this store
  does not hold it, so the chain carries on.

  MATCHED ON THE WHOLE PHRASE, NOT ON \"not found\". SecretSpec also says
  `Provider backend 'keyring' not found`, which is a store that could not
  answer at all - and reading that as a miss is the worst failure this
  library has, because the chain then falls through to a weaker store
  without saying so. The key is required to appear, so the two cannot be
  confused."
  [why key]
  (string/includes? why (str "Secret '" key "' not found")))

(defrecord Secretspec [command file profile backend reason prefix]
  provider/Provider

  ;; SecretSpec (https://secretspec.dev).
  ;;
  ;; SecretSpec is a declaration - a `secretspec.toml` naming the secrets a
  ;; project needs - plus a chain of its own backends to satisfy them from.
  ;; That makes it the same shape as sekreto one level down, and the reason
  ;; to support it is the same reason sekreto exists: a project that has
  ;; already declared its secrets there should not have to declare them
  ;; again here.
  ;;
  ;; Read through its CLI, as boru is, because that is the interface it
  ;; offers a program in another language: `secretspec get API_TOKEN` prints
  ;; the value on stdout and nothing else. A sekreto name maps to a
  ;; SecretSpec key exactly as it maps to an environment variable -
  ;; `api.token` is `API_TOKEN` - which is the convention SecretSpec's own
  ;; examples use.
  ;;
  ;; `backend` selects one of SecretSpec's backends (`--provider`, e.g.
  ;; `keyring` or `dotenv://.env`) and is called `backend` here only because
  ;; `provider` already means something else in this library.
  ;;
  ;; A reason is required, not optional: SecretSpec records every read in an
  ;; audit log and refuses to read at all without one. sekreto sends
  ;; `sekreto` unless told otherwise, so the audit trail says which tool
  ;; asked.
  (lookup [_ name]
    (let [key (core/envkey name prefix)
          args (cond-> [command]
                 (core/notempty file) (conj "--file" file)
                 true (conj "get" key)
                 (core/notempty backend) (conj "--provider" backend)
                 (core/notempty profile) (conj "--profile" profile)
                 true (conj "--reason" (or (core/notempty reason) "sekreto")))
          ran (proc/runcmd (proc/command args) command)]

      (cond
        ;; The value and one newline, and nothing else.
        (= 0 (:status ran)) (core/dropsuffix (:out ran) "\n")

        (secretspecmiss? (:why ran) key) nil

        :else
        (throw (core/sekretoerror
                (str "sekreto: secretspec error: "
                     (if (= "" (:why ran)) (str "exit " (:status ran)) (:why ran))))))))

  (describe [_]
    (str "secretspec" (when (core/notempty backend) (str ":" backend)))))

(def secretspec
  "The `secretspec` provider kind."
  (providers/providerplugin
   "secretspec"
   (fn [{:keys [command file profile backend reason prefix]}]
     (->Secretspec (or (core/notempty command) "secretspec")
                   file profile backend reason prefix))))
