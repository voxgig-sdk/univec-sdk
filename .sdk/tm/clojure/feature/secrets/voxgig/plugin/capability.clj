;; VENDORED: @voxgig/plugin sdk-20260908-1556-0 (clojure/src/voxgig/plugin/capability.clj)
;; Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
(ns voxgig.plugin.capability
  "Capabilities (section 11.1).

  A DEPENDENCY IS ON A CAPABILITY, NOT ON A REF - because it is a
  dependency on something that can do the job, and which instance is doing
  it is exactly the configuration detail a plugin must not care about.

  But A BINDING IS TO AN INSTANCE, not to a capability, which is what
  decides behaviour when the bound provider leaves while another match
  remains."
  (:require [voxgig.plugin.types :as t]
            [voxgig.plugin.version :as v]))

(defn match-value
  "PARTIAL MATCH, RECURSING INTO MAPS (section 11.1).

  Every leaf in the requirement must be present and equal in the
  capability; keys not mentioned are not checked. Equality is by JSON TYPE
  as well as value: `transactional: 1` does not satisfy
  `transactional: true`. CLOJURE NEEDS NO GUARD FOR THAT - `(= true 1)` is
  false, because Boolean and Long are different classes with no coercion.
  Python, PHP, Perl and Lua all need one, and `capability/match` pins the
  behaviour for every port rather than trusting each language's equality.

  A LIST IS COMPARED LEAF-WISE AT THE SAME LENGTH, not as a subset."
  [want got]
  (cond
    (map? want) (and (map? got)
                     (every? (fn [[k w]] (and (contains? got k) (match-value w (got k))))
                             want))
    (sequential? want) (and (sequential? got)
                            (= (count want) (count got))
                            (every? identity (map match-value want got)))
    :else (t/same want got)))

(defn matches? [req prov]
  (and (= (t/get req "name") (t/get prov "name"))
       (or (nil? (t/get req "range"))
           (and (some? (t/get prov "version"))
                (v/satisfies-q? (t/get prov "version") (t/get req "range"))))
       ;; `match` is checked against the provider's `attrs`, key by key. A
       ;; key the provider does not carry is a miss, not a pass: a
       ;; requirement asking for `transactional: true` must not be
       ;; satisfied by a provider that never said.
       (or (nil? (t/get req "match"))
           (let [attrs (or (t/get prov "attrs") {})]
             (every? (fn [k] (and (contains? attrs k)
                                  (match-value (t/get (t/get req "match") k) (attrs k))))
                     (t/sorted-keys (t/get req "match")))))))

(defn rank-key
  "An ABSENT version sorts LAST, whatever the other is - \"no version\"
  loses to every version rather than being read as 0.0.0. The leading flag
  is what expresses that in a sort KEY rather than a comparator."
  [cand]
  (let [prov (or (t/get cand "provides") {})
        version (t/get prov "version")]
    [(if (nil? version) 1 0)
     (if (nil? version) [0 0 0] (mapv - (v/version-parts version)))
     (or (t/get prov "priority") 0)
     (or (t/get cand "pos") 0)]))

(defn resolve-capability
  "Rank the matching live providers and return them best-first: highest
  `version`, then LOWEST `priority` (default 0), then declaration position
  `pos` ascending.

  `priority` is a field on the capability rather than section 7's `order`
  band, because bands live on POINT BINDINGS: a provider may have several
  bindings with different bands, or none at all, so a rank reaching for
  one would be undefined in the common case.

  Without a total rank, \"any provider satisfies\" is true of the GRAPH
  and useless to the PLUGIN - two ports could bind different `store`
  instances, both resolve green, and behave differently, which is
  precisely the divergence a shared corpus exists to catch."
  [req candidates]
  (->> candidates
       (filter #(matches? req (or (t/get % "provides") {})))
       (t/stable-sort-by rank-key)
       vec))
