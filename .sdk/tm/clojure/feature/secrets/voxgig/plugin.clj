;; VENDORED: @voxgig/plugin sdk-20260908-1556-0 (clojure/src/voxgig/plugin.clj)
;; Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
(ns voxgig.plugin
  "The canonical surface `make parity` checks (AGENTS.md section 4). Small
  on purpose (section 19): everything else is functions on the host and
  instance types, because a library that grows a second public entry point
  per feature is a library twenty ports pay for twice.

  ELEVEN NAMES, AND THEY ARE ALIASES RATHER THAN DEFINITIONS - a plain
  `def` of the function value, not a wrapper that forwards. The
  implementation lives in the namespace named for its design section, so a
  reader who arrives at `resolve-order` from the corpus lands in
  `voxgig.plugin.order` where section 7 is quoted. No `potemkin`: section
  16 permits one runtime dependency, and importing vars prettily is not
  what it is for."
  (:require [voxgig.plugin.catalog :as catalog]
            [voxgig.plugin.config :as config]
            [voxgig.plugin.env :as env]
            [voxgig.plugin.host :as host]
            [voxgig.plugin.order :as order]
            [voxgig.plugin.ref :as ref]
            [voxgig.plugin.resolve :as resolve]))

;; host construction
(def make-host host/make-host)
(def make-catalog catalog/make-catalog)

;; refs - the first thing a new port implements (section 4)
(def parse-ref ref/parse-ref)
(def format-ref ref/format-ref)
(def check-name ref/check-name)
(def check-tag ref/check-tag)

;; pure functions over documents and definitions
(def normalize-config config/normalize-config)
(def resolve-options config/resolve-options)
(def resolve-order order/resolve-order)
(def resolve-candidates resolve/resolve-candidates)
(def apply-env env/apply-env)
