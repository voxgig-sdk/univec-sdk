;; VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (clojure/plugins/voxgig/sekreto/plugins/boru.clj)
;; Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
;; A boru vault, as a voxgig/plugin definition.
;;
;; A plugin rather than a built-in kind because it spawns a child process
;; (the CLI) or opens a socket (the wire protocol), and a built-in kind
;; reads at most a local file (docs/design/plugin-providers.md).
;;
;; A port of typescript/plugins/boru.ts, which is canonical.

(ns voxgig.sekreto.plugins.boru
  (:require [clojure.string :as string]
            [voxgig.sekreto.core :as core]
            [voxgig.sekreto.addr :refer [checkaddr]]
            [voxgig.sekreto.json :as json]
            [voxgig.sekreto.provider :as provider]
            [voxgig.sekreto.providers :as providers]
            [voxgig.sekreto.plugins.httpjson :as http]
            [voxgig.sekreto.plugins.proc :as proc]))

(defn borumiss?
  "Does this boru failure mean \"no such secret\" rather than \"I could not
  answer\"? Matched on boru's own wording for a missing alias."
  [why]
  (string/includes? why "no alias named"))

(defrecord Boru [command namespace home addr token mount]
  provider/Provider

  ;; A boru vault (https://github.com/boru-lang/boru).
  ;;
  ;; Two ways in, both boru's own.
  ;;
  ;; With no `addr`, the CLI: `boru vault get --reveal <alias>` prints the
  ;; secret on stdout and nothing else. The passphrase is read by boru
  ;; itself from `BORU_VAULT_PASSPHRASE`; sekreto never accepts it as config
  ;; and never puts it on a command line, where it would show up in the
  ;; process table.
  ;;
  ;; With an `addr`, boru's wire protocol: `boru vault serve` publishes a
  ;; read-only, HashiCorp-shaped provision API (boru's
  ;; design/VAULT-WIRE-PROTOCOL.0.md), authenticated by a capability token
  ;; from `boru vault grant`. A sekreto name is already a valid boru alias,
  ;; and boru aliases keep their dots, so `api.token` is the single path
  ;; segment `api.token` - not the `api`/`token` split a HashiCorp KV gets.
  ;; The value is the `value` field. A 404 is a miss; anything else the
  ;; server refuses (a revoked capability, a sealed vault) is an error.
  ;;
  ;; boru's `vault proxy` and `vault mcp` remain out of bounds: they are a
  ;; credential *broker*, built precisely so the caller never receives the
  ;; credential. `vault serve` is the provision endpoint, built to hand the
  ;; value back - that is the one sekreto uses.
  (lookup [_ name]
    (core/checkname name)

    (if (core/notempty addr)
      (do
        (checkaddr addr)
        ;; The dotted name stays one path segment: boru aliases keep dots.
        (let [alias (if (core/notempty namespace) (str namespace "/" name) name)
              url (str (http/trimslash addr) "/v1/" mount "/data/" alias)
              res (http/fetchjson "GET" url {"X-Vault-Token" (or token "")})]
          (cond
            (= 404 (:status res)) nil

            (not= 200 (:status res))
            (throw (core/sekretoerror (str "sekreto: boru serve error: " (:status res) ": " url)))

            :else (json/astext (json/dig (:body res) "data" "data" "value")))))

      (let [alias (if (core/notempty namespace) (str namespace ":" name) name)
            builder (proc/command [command "vault" "get" "--reveal" alias])]

        (when (core/notempty home)
          (.put (.environment builder) "BORU_HOME" home))

        (let [ran (proc/runcmd builder command)]
          (cond
            ;; boru prints the value and one newline, and nothing else.
            (= 0 (:status ran)) (core/dropsuffix (:out ran) "\n")

            ;; "no alias named" is boru saying it does not hold this secret,
            ;; which is a miss: the chain carries on to the next provider. A
            ;; locked vault or a wrong passphrase is not a miss - treating
            ;; it as one would fall through to a weaker store without saying
            ;; so.
            (borumiss? (:why ran)) nil

            :else
            (throw (core/sekretoerror
                    (str "sekreto: boru vault error: "
                         (if (= "" (:why ran)) (str "exit " (:status ran)) (:why ran))))))))))

  (describe [_]
    (if (core/notempty addr)
      (str "boru:" addr)
      (str "boru" (when (core/notempty namespace) (str ":" namespace))))))

(def boru
  "The `boru` provider kind."
  (providers/providerplugin
   "boru"
   (fn [{:keys [command namespace home addr token mount]}]
     (->Boru (or (core/notempty command) "boru") namespace home
             (some-> (core/notempty addr) http/trimslash) token
             (or (core/notempty mount) "secret")))))
