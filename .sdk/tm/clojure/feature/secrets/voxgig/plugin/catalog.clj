;; VENDORED: @voxgig/plugin sdk-20260908-1556-0 (clojure/src/voxgig/plugin/catalog.clj)
;; Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
(ns voxgig.plugin.catalog
  "The definition catalog (section 10.1).

  A definition is registered once and may back many instances. Option
  shapes are validated AT REGISTRATION, not when a document happens to
  exercise a key - so a malformed shape fails once, and in the same place
  everywhere (section 9.4).

  THE CATALOG IS A VALUE HERE, not an object with an `add` method. Every
  other port hands out a mutable catalog and lets the host and its caller
  share it; a clojure map cannot be mutated, so `add` RETURNS the new
  catalog and the host - whose registry is the one atom in the port - owns
  the one it reads. `host/catalog-add!` is how a caller extends a live
  host's catalog, and it is the only path that has to exist: a caller
  holding a catalog value simply keeps the result of `add`."
  (:require [voxgig.plugin.types :as t]
            [voxgig.plugin.ref :as r]
            [voxgig.plugin.config :as config]))

(defn add [catalog definition]
  (let [nm (t/get definition "name")]
    (when-not (and (map? definition) (r/check-name nm))
      (t/fail "plugin_definition_name"
              (str "invalid definition name: "
                   (t/encode (if (map? definition) nm definition)))))
    ;; Validate the shape HERE. Deferring it to resolution time means a
    ;; malformed shape surfaces at a different moment in every host that
    ;; loads it, which is the divergence the stated domain exists to
    ;; prevent.
    (when-let [shape (t/get definition "shape")] (config/check-shape shape))
    (assoc catalog nm definition)))

(defn make-catalog
  ([] (make-catalog nil))
  ([definitions] (reduce add {} (or definitions []))))

(defn definition-of [catalog nm] (t/get catalog nm))

(defn has-definition? [catalog nm] (t/has? catalog nm))

(defn definition-names [catalog] (vec (t/sorted-keys catalog)))
