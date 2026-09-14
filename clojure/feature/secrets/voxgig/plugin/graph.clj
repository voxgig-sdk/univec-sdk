;; VENDORED: @voxgig/plugin sdk-20260908-1556-0 (clojure/src/voxgig/plugin/graph.clj)
;; Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
(ns voxgig.plugin.graph
  "Whole-graph resolution (section 11.4) - a phase, not a discovery.

  \"Activate, and wait in `pending` if you must\" is correct and, on its
  own, produces a terrible experience: apply twenty instances against a
  registry missing one thing and you get NINETEEN pending rows and no
  statement of what is actually wrong.

  `resolve-graph` is a PURE FUNCTION of the registry and the intended
  activation set. No callbacks run, no state changes, nothing is touched.
  It answers for the whole graph at once which instances can be live, and
  for each blocked one THE SPECIFIC REQUIREMENT that is unmet, and why.

  The failure mode being designed against is a famous one: OSGi's resolver
  is correct and its diagnostics are legendarily unusable. A resolver that
  says \"blocked\" without saying WHY has moved the problem rather than
  solved it, so `why` is part of the contract and the corpus pins its
  shape."
  (:require [voxgig.plugin.types :as t]
            [voxgig.plugin.capability :as cap]
            [voxgig.plugin.ref :as r]
            [voxgig.plugin.version :as v]))

;; A NODE SATISFIES ITS OWN REF (section 11.1), and the graph learned it
;; here. Considering only declared capabilities made `resolve` answer
;; `absent` about a provider sitting right there and live - section 11.4's
;; job is explaining the graph the runtime reconciles, and it was
;; explaining a different one. The ref match WINS OUTRIGHT for that node,
;; as at runtime: one candidate, not two, for a node both named `b` and
;; providing `b`.
(defn graph-candidates [byref nm]
  (let [asref (r/canon nm)]
    (vec (mapcat (fn [ref]
                   (let [node (byref ref)]
                     (if (= ref asref)
                       [{"ref" (t/get node "ref")
                         "pos" (or (t/get node "pos") 0)
                         "provides" {"name" nm}}]
                       (for [prov (or (t/get node "provides") [])
                             :when (= nm (t/get prov "name"))]
                         {"ref" (t/get node "ref")
                          "pos" (or (t/get node "pos") 0)
                          "provides" prov}))))
                 (t/sorted-keys byref)))))

(defn- why [node nm reason]
  {"ref" (t/get node "ref") "unmet" nm "why" reason})

(defn- bad-versions [all range]
  (->> all
       (map #(t/get (t/get % "provides") "version"))
       (filter #(or (nil? %) (not (v/satisfies-q? % range))))
       (map #(or % "(none)"))
       vec))

(defn- bad-attr [node req match cand]
  (let [attrs (or (t/get (t/get cand "provides") "attrs") {})]
    (first (for [k (t/sorted-keys match)
                 :let [want (t/get match k)]
                 :when (not (and (t/has? attrs k) (cap/match-value want (t/get attrs k))))]
             (why node (t/get req "name")
                  {"kind" "match" "failing" k "want" want "found" (t/get attrs k)})))))

(defn- why-no-match
  "Providers exist and none matched. Say which test failed."
  [node req all]
  (let [range (t/get req "range")
        match (t/get req "match")
        bad (if (nil? range) [] (bad-versions all range))]
    (cond
      (seq bad) (why node (t/get req "name")
                     {"kind" "version" "range" range "found" (vec (sort bad))})
      (some? match) (first (keep #(bad-attr node req match %) all))
      :else nil)))

(defn- unmet [node req byref resolved]
  (let [nm (t/get req "name")
        all (graph-candidates byref nm)
        ok (cap/resolve-capability req all)]
    (cond
      (empty? all) (why node nm {"kind" "absent"})
      (empty? ok) (or (why-no-match node req all) (why node nm {"kind" "absent"}))
      (some #(contains? resolved (t/get % "ref")) ok) nil
      ;; A provider exists and matches - but if none of them is itself
      ;; resolved, this node is blocked BEHIND it, and the chain is the
      ;; useful answer rather than "unmet".
      :else (why node nm {"kind" "blocked"
                          "chain" (vec (sort (map #(t/get % "ref") ok)))}))))

(defn first-unmet
  "The FIRST unmet requirement, with the most specific explanation
  available. Order matters: \"no provider at all\" and \"a provider at the
  wrong version\" are different problems and a reader must not have to
  guess which they have."
  [node byref resolved]
  (first (keep #(unmet node % byref resolved)
               (remove #(t/truthy (t/get % "optional")) (or (t/get node "requires") [])))))

(defn resolve-graph [nodes]
  (let [byref (reduce #(assoc %1 (t/get %2 "ref") %2) {} nodes)
        ;; Fixed point: a node resolves when every mandatory requirement is
        ;; met by an ALREADY-RESOLVED provider. Iterating to a fixed point
        ;; is what makes a provider that is itself blocked propagate,
        ;; rather than each node being judged against the raw registry.
        resolved (loop [acc #{}]
                   (let [next (reduce (fn [a n]
                                        (if (or (contains? a (t/get n "ref"))
                                                (some? (first-unmet n byref a)))
                                          a
                                          (conj a (t/get n "ref"))))
                                      acc
                                      nodes)]
                     (if (= (count next) (count acc)) acc (recur next))))]
    {"resolved" (vec (sort resolved))
     "blocked" (->> nodes
                    (remove #(contains? resolved (t/get % "ref")))
                    (keep #(first-unmet % byref resolved))
                    (sort-by #(t/get % "ref"))
                    vec)}))
