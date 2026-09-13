;; VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (clojure/src/voxgig/sekreto/provider.clj)
;; Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
;; A source of secrets.
;;
;; A provider answers one question: "do you have this secret?" It returns
;; the value, or nil to mean "ask the next one". Nothing else about a
;; provider is visible to the caller - which is the point: an app reads
;; `api.token` and never learns whether it came from the environment, a
;; .env file, HashiCorp Vault or a boru vault.
;;
;; A protocol rather than a map of functions: a provider of your own is any
;; type that satisfies it, and `satisfies?` can say so before a chain is
;; built.

(ns voxgig.sekreto.provider)

(defprotocol Provider

  (lookup [this name]
    "The value, or nil if this provider does not have it.")

  (describe [this]
    "A short description, shown by `sources`. It opens with the provider's
    kind, because that is what a store's default name is taken from."))
