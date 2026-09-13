;; VENDORED: @voxgig/plugin sdk-20260908-1556-0 (clojure/src/voxgig/plugin/export.clj)
;; Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
(ns voxgig.plugin.export
  "Exports (section 11).

  An instance publishes values for other plugins and for the application.
  Read with `(host/exports h \"retry$fast/client\")`.

  THE UNQUALIFIED ALIAS IS THE INTERESTING PART. `retry/client` resolves
  to the UNTAGGED instance if one exists; if not, and exactly one tagged
  instance exports that key, it resolves to that one; if two do, it is
  `plugin_export_ambiguous` - deliberately diverging from seneca's silent
  last-wins, because with multi-instance as a headline feature an
  ambiguous alias is a defect waiting for production."
  (:require [voxgig.plugin.types :as t]
            [voxgig.plugin.ref :as r]))

(defn resolve-export
  "`exported` is a list of `{:ref :key :value}` - an internal shape, never
  a corpus value, so it uses keyword keys where the data does not."
  [spec exported]
  (let [cut (.indexOf ^String spec "/")]
    (when (neg? cut)
      (t/fail "plugin_export_ambiguous" (str "export spec needs a key: " spec)
              {"spec" spec}))
    (let [head (subs spec 0 cut)
          k (subs spec (inc cut))
          want (r/canon head)
          ;; A fully qualified ref: exactly one answer or none.
          qualified (first (filter #(and (= (:ref %) want) (= (:key %) k)) exported))]
      (if qualified
        (:value qualified)
        ;; An alias: the name, not a ref. Look at every instance of it.
        (let [byname (filter #(and (= (r/ref-name (:ref %)) head) (= (:key %) k)) exported)
              untagged (first (filter #(empty? ((r/parse-ref (:ref %)) "tag")) byname))]
          (cond
            (empty? byname) nil
            untagged (:value untagged)
            (= 1 (count byname)) (:value (first byname))
            :else
            (let [refs (sort (map :ref byname))]
              (t/fail "plugin_export_ambiguous"
                      (str "alias " spec " matches " (count refs) " instances: "
                           (clojure.string/join ", " refs))
                      {"spec" spec "refs" (vec refs)}))))))))
