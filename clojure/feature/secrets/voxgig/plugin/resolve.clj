;; VENDORED: @voxgig/plugin sdk-20260908-1556-0 (clojure/src/voxgig/plugin/resolve.clj)
;; Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
(ns voxgig.plugin.resolve
  "Dynamic resolution (section 10.2) - name to candidate module ids.

  PURE. It returns the ids a host WOULD try, in order; it does not load
  anything. That separation is what lets the corpus pin resolution in
  every language including those with no dynamic loading at all, and it is
  why section 15.4 puts real module loading in per-port integration tests
  rather than here."
  (:require [voxgig.plugin.types :as t]
            [clojure.string :as str]))

(def default-sources
  [{"kind" "module" "prefix" ["@voxgig/plugin-" "voxgig-plugin-" "plugin-" ""]}])

(defn- ids-for [src nm]
  (case (t/get src "kind")
    "module" (let [prefixes (t/get src "prefix")
                   prefixes (if (empty? prefixes) [""] prefixes)]
               (map #(str % nm) prefixes))
    "path" [(str (str/replace (t/get src "dir") #"/+\z" "") "/" nm)]
    []))

(defn resolve-candidates
  ([nm] (resolve-candidates nm nil))
  ([nm sources]
   ;; A SCOPED NAME RESOLVES VERBATIM ONLY (section 10.2). `@acme/thing`
   ;; is already a package id; prefixing it produces
   ;; `@voxgig/plugin-@acme/thing`, which is not a thing that can exist.
   (if (str/starts-with? nm "@")
     [nm]
     (->> (if (empty? sources) default-sources sources)
          (mapcat #(ids-for % nm))
          distinct
          vec))))

(defn resolve-from
  "A MODULE PATH IS NOT A NAME (section 10.2). The ref grammar starts a
  name with a letter or `@`, so `./local/thing` is not a ref and never
  reaches candidate generation - seneca allows a path where a plugin name
  goes, and this design deliberately does not, because a ref is an ADDRESS
  WITHIN A HOST and a path is a LOCATION ON A DISK."
  [from]
  [from])
