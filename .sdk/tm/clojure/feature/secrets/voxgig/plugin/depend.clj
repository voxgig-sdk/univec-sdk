;; VENDORED: @voxgig/plugin sdk-20260908-1556-0 (clojure/src/voxgig/plugin/depend.clj)
;; Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
(ns voxgig.plugin.depend
  "Dependency cardinality, policy, and the restart graph (section 11.3).

  TWO AXES, BOTH DECLARED BY THE DEFINITION THAT HAS THE REQUIREMENT,
  because only it knows what it can cope with:

                 | static (default)          | dynamic
    -------------|---------------------------|-------------------------
    mandatory    | unmet -> pending;         | unmet -> pending;
    (default)    | lost  -> pending,         | lost  -> STAYS LIVE,
                 |          recursively      |          notified
    -------------|---------------------------|-------------------------
    optional:true| never gates activation;   | never gates activation;
                 | a change deactivates and  | a change is a
                 | reactivates               | notification, nothing else

  `dynamic` means the plugin has said, IN WRITING, that it can survive its
  provider being swapped underneath it. It is not the default because most
  plugins cannot, and the cost of wrongly assuming they can is a live
  instance holding a dead reference.

  The rebinding-preference axis is deliberately omitted. OSGi has
  reluctant vs greedy and it is a knob every author must understand to
  read anyone else's component; we take always-reluctant. Three axes were
  more than the model can carry across twenty ports."
  (:require [voxgig.plugin.types :as t]
            [voxgig.plugin.ref :as r]))

(defn norm-require
  "A bare string is shorthand for `{name}`."
  [raw]
  (cond (string? raw) {"name" raw}
        (map? raw) raw
        :else {}))

(defn requirements
  "The requirements a definition declared, normalized.

  BOTH AXES ARE READ AT TWO LEVELS, AND THE PER-REQUIREMENT ONE WINS.

  The instance-level `policy` and `optional` list are how a DOCUMENT
  states the axis without editing the definition, and they apply to every
  requirement. The per-requirement form is the one section 11.1's object
  syntax exists for, and it is strictly more expressive: an instance that
  is `static` on its store and `dynamic` on its metrics cannot be written
  at all at the instance level.

  `optional` unions rather than overriding - both spellings are statements
  that this requirement need not gate activation, and there is no reading
  under which one of them means \"actually, mandatory\"."
  [options]
  (let [raw (or (t/get options "requires") [])
        marked (t/get options "optional")
        fallback (t/get options "policy")]
    (vec (for [item raw]
           (let [req (norm-require item)
                 req (if (or (t/truthy (t/get req "optional"))
                             (and (sequential? marked)
                                  (boolean (some #(= % (t/get req "name")) marked))))
                       (assoc req "optional" true)
                       req)]
             (if (and (nil? (t/get req "policy")) (some? fallback))
               (assoc req "policy" fallback)
               req))))))

(defn restarts-on-loss?
  "Does losing this requirement's SELECTED provider restart the consumer?
  The mandatory ones under `static`, and the `static` optional ones - both
  make a capability change deactivate and reactivate. `dynamic` never
  restarts."
  [req]
  (not= "dynamic" (or (t/get req "policy") "static")))

(defn gates-activation?
  "Does an unmet requirement keep the consumer out of `live`?

  Cardinality alone decides this, NOT policy. `dynamic` is a statement
  about surviving a SWAP, not about starting without the thing at all - a
  mandatory-dynamic consumer still waits in `pending` for its first
  provider."
  [req]
  (not= true (t/get req "optional")))

(defn restart-causing?
  "Edges that can cause a restart, which is exactly the set a cycle must be
  detected over (section 11.3).

  ONLY `dynamic` OPTIONAL EDGES ARE EXCLUDED, and they are the ones the
  exclusion was for: two plugins that optionally and dynamically consume
  each other's capabilities both activate happily, neither gates on the
  other, and each is merely notified when the other appears. Nothing
  restarts, so nothing oscillates. An earlier draft of section 11.3
  excluded EVERY optional edge and thereby admitted the non-terminating
  case it was trying to permit."
  [req]
  (or (gates-activation? req) (restarts-on-loss? req)))

;; TWO INDEXES, NOT ONE MERGED MAP. Capability names and refs are matched
;; differently - a capability by its exact name, a ref through the
;; canonical spelling (section 4 rule 5) - and one map keyed by both can
;; only do one of them. Keyed by both and looked up raw, as this was, a
;; cycle spelled `a$`/`b$` found no providers and EVADED the load-time
;; check that exists to catch a non-terminating reconcile.
(defn- providers-of [nodes]
  (reduce (fn [acc n]
            (reduce #(update %1 %2 (fnil conj []) (:ref n)) acc (vec (:provides n))))
          {}
          nodes))

(defn- edges-of [nodes]
  (let [bycap (providers-of nodes)
        isref (set (map :ref nodes))]
    (into {}
          (for [n nodes]
            [(:ref n)
             (vec (sort (distinct (for [req (:requires n)
                                        :when (restart-causing? req)
                                        ;; A node satisfies its own name AS
                                        ;; A REF (section 11.1),
                                        ;; canonically - exactly what
                                        ;; `providers-of` does at runtime.
                                        ;; `canon` hands back a name no ref
                                        ;; could have unchanged, and no
                                        ;; instance ref can equal one.
                                        p (let [nm (t/get req "name")
                                                from (or (bycap nm) [])
                                                asref (r/canon nm)]
                                            (if (isref asref)
                                              (conj (vec from) asref)
                                              from))
                                        :when (not= p (:ref n))]
                                    p))))]))))

(defn dependency-cycle
  "A cycle through restart-causing requirements is
  `plugin_dependency_cycle`, detected AT LOAD - before anything runs,
  because the failure it describes is a non-terminating reconcile and the
  only safe time to report that is before it starts.

  The graph is over capabilities, not refs: an edge runs from a consumer
  to EVERY node that provides what it needs, because any of them could be
  the one selected and a cycle through any is a cycle. A node also
  satisfies its own name as a ref (section 11.1), which is why the ref is
  a provider of itself here.

  `nodes` is a list of `{:ref :provides :requires}`.

  Iterative DFS with an explicit stack: twenty ports, and several of them
  have no recursion budget worth relying on. Clojure is one - it has no
  tail-call elimination, and `recur` cannot express a DFS's two-way
  branch."
  [nodes]
  (let [edges (edges-of nodes)]
    (loop [starts (sort (keys edges))
           colour (zipmap (map :ref nodes) (repeat :white))]
      (if (empty? starts)
        nil
        (let [start (first starts)]
          (if (not= :white (colour start))
            (recur (rest starts) colour)
            (let [result
                  (loop [path [start]
                         stack [[start 0]]
                         colour (assoc colour start :grey)]
                    (if (empty? stack)
                      [nil colour]
                      (let [[node at] (peek stack)
                            outs (edges node)]
                        (if (<= (count outs) at)
                          (recur (pop path) (pop stack) (assoc colour node :black))
                          (let [nxt (outs at)
                                stack (conj (pop stack) [node (inc at)])]
                            (cond
                              ;; Report the cycle itself, not the walk
                              ;; that found it.
                              (= :grey (colour nxt))
                              [(vec (concat (subvec path (.indexOf ^java.util.List path nxt))
                                            [nxt]))
                               colour]

                              (= :black (colour nxt)) (recur path stack colour)
                              :else (recur (conj path nxt)
                                           (conj stack [nxt 0])
                                           (assoc colour nxt :grey))))))))]
              (if (first result)
                (first result)
                (recur (rest starts) (second result))))))))))

(defn check-cycle
  "Raise on a cycle, naming it. Separate from the detector so the detector
  stays pure and corpus-testable."
  [nodes]
  (when-let [cycle (dependency-cycle nodes)]
    (t/fail "plugin_dependency_cycle"
            (str "requirements cycle: " (clojure.string/join " -> " cycle))
            {"cycle" cycle})))
