;; VENDORED: @voxgig/plugin sdk-20260908-1556-0 (clojure/src/voxgig/plugin/order.clj)
;; Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
(ns voxgig.plugin.order
  "Ordering (section 7) - one rule, one place.

  sdkgen grew two special cases in `makeOptions` (`test`, then `station`)
  and the third was not far off. This sort is the whole replacement, and
  the tiers are in this order for a reason:

    1 constraints   before/after edges, by ref or by name
    2 bands         integer, lower first, default 0
    3 declaration   ties break by `pos`

  CONSTRAINTS BEAT BANDS precisely so the correct tool wins when both are
  present. A band expresses a genuine cross-cutting layer; a constraint
  expresses a relationship between two specific things; and a band chosen
  by trial and error to fix an ordering bug is a bug wearing a number."
  (:require [voxgig.plugin.types :as t]
            [voxgig.plugin.ref :as r]))

(defn order-band
  "An integer, and only an integer: `true` and `\"2\"` are not bands."
  [binding]
  (or (t/asint (t/get (or (:order binding) {}) "band")) 0))

(defn order-declared?
  "Was a constraint stated? An absent value and an EMPTY LIST are both
  no-constraint - and an empty list is TRUTHY in most languages, which is
  exactly how this class of bug survives a reading."
  [spec]
  (cond
    (nil? spec) false
    (sequential? spec) (boolean (some #(not= "" %) spec))
    :else (not= "" spec)))

(defn order-targets
  "One spelling or a LIST of them. A list fans out to the UNION of what
  each names, so after: ['a','b'] means after BOTH, and the same instance
  named twice - once by name, once by ref - is one edge.

  Matching is by REF, or by NAME across all of that definition's instances
  (section 7) - which is the whole reason the two spellings exist."
  [spec nodes]
  (let [specs (if (sequential? spec) spec [spec])]
    (vec (distinct (for [one specs
                         b nodes
                         :when (or (= (:ref b) one) (= (r/ref-name (:ref b)) one))]
                     (:ref b))))))

(defn- build-edges [nodes]
  (reduce (fn [edges b]
            (let [block (or (:order b) {})
                  edges (if (order-declared? (t/get block "after"))
                          (reduce #(update %1 %2 conj (:ref b))
                                  edges
                                  (order-targets (t/get block "after") nodes))
                          edges)]
              (if (order-declared? (t/get block "before"))
                (update edges (:ref b) into (order-targets (t/get block "before") nodes))
                edges)))
          (zipmap (map :ref nodes) (repeat []))
          nodes))

(defn- walk
  "Stable topological sort. Among ready nodes, band first (lower runs
  first), then `pos` - the position the DOCUMENT visibly states, not the
  order instances happened to load and not the incarnation `seq`."
  [ready indeg edges byref out]
  (if (empty? ready)
    out
    (let [[nxt & rest] (t/stable-sort-by (fn [b] [(order-band b) (or (:pos b) 0)]) ready)
          [indeg added] (reduce (fn [[ind acc] to]
                                  (let [ind (update ind to dec)]
                                    (if (zero? (ind to))
                                      [ind (conj acc (byref to))]
                                      [ind acc])))
                                [indeg []]
                                (edges (:ref nxt)))]
      (recur (concat rest added) indeg edges byref (conj out (:ref nxt))))))

(declare apply-pin)

(defn resolve-order
  "`bindings` is a list of `{:ref :pos :order}` - an internal shape, never
  a corpus value, so it uses keyword keys where the data does not."
  ([bindings] (resolve-order bindings nil))
  ([bindings pin]
   (let [nodes (vec bindings)
         byref (zipmap (map :ref nodes) nodes)
         ;; Constraints are edges. A constraint naming an ABSENT binding
         ;; is satisfied VACUOUSLY (section 7) - a plugin ordered
         ;; `after: 'test'` must load in a host with no test plugin. That
         ;; is sdkgen's __after__ behaviour, kept.
         edges (build-edges nodes)
         indeg (reduce (fn [ind tos] (reduce #(update %1 %2 inc) ind tos))
                       (zipmap (map :ref nodes) (repeat 0))
                       (vals edges))
         out (walk (filter #(zero? (indeg (:ref %))) nodes) indeg edges byref [])]
     (when (not= (count out) (count nodes))
       (let [stuck (vec (remove (set out) (map :ref nodes)))]
         (t/fail "plugin_order_cycle"
                 (str "before/after constraints cycle: " (clojure.string/join " -> " stuck))
                 {"cycle" stuck})))
     (apply-pin out edges pin))))

(defn- place [out nm want]
  (let [idx (first (keep-indexed #(when (= (r/ref-name %2) nm) %1) out))]
    (if (nil? idx)
      out
      ;; `first`/`outermost` is index 0; `last`/`innermost` is the end.
      ;; Section 6.2 makes the first chain binding outermost, which is why
      ;; the vocabulary is positional and why the two spellings pair this
      ;; way.
      (let [ref (out idx)
            rest (vec (concat (subvec out 0 idx) (subvec out (inc idx))))]
        (if (contains? #{"first" "outermost"} want)
          (vec (cons ref rest))
          (conj rest ref))))))

(defn apply-pin
  "A PIN IS NOT A CONSTRAINT (section 7).

  Constraints and bands are negotiable by definition - they are what
  plugins and documents say they want, and the sort's job is to satisfy
  them all. A pin is the host stating a structural invariant of its own
  architecture, which is a different kind of claim and must not lose a tie
  to a document.

  So a pin PLACES the binding at the named end, and an ordering that would
  move it away is `plugin_order_pinned` - rejected, not honoured into a
  broken wrap."
  [order edges pin]
  (if (nil? pin)
    (vec order)
    ;; SORTED, not insertion order. A pin map is data - it can arrive from
    ;; a host's own construction options in any order, and two names
    ;; pinned to the same end are order-sensitive (`{b:'first',
    ;; a:'first'}` and `{a:'first', b:'first'}` give different results).
    ;; A clojure hash-map has no order at all, so leaving it unstated made
    ;; the same declaration mean different things in different ports.
    (let [out (reduce (fn [acc nm] (place acc nm (t/get pin nm)))
                      (vec order)
                      (t/sorted-keys pin))
          ;; Now check that the placement did not break a constraint. This
          ;; is the half that makes a pin a rejection rather than an
          ;; override: the host wins on position, but it does not get to
          ;; silently discard a relationship a plugin declared.
          at (zipmap out (range))]
      (doseq [[from tos] edges
              to tos
              :when (< (at to) (at from))]
        (t/fail "plugin_order_pinned"
                (str "a pin would move a binding an ordering constrains: "
                     from " must precede " to)
                {"before" from "after" to}))
      out)))
