;; VENDORED: @voxgig/plugin sdk-20260908-1556-0 (clojure/src/voxgig/plugin/point.clj)
;; Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
(ns voxgig.plugin.point
  "Extension points (section 6). Three kinds, chosen because they are what
  the two existing systems actually needed, and no more.

  A PLUGIN NEVER MUTATES THE HOST. That inversion is what makes
  deactivation possible: sdkgen's `utility.fetcher = wrapped` is not
  undoable, but \"this instance holds slot 3 of the request chain\" is
  undoable in O(1). OSGi named it the whiteboard pattern in 2004, in a
  paper called *Listeners Considered Harmful*, and for exactly this
  reason."
  (:require [voxgig.plugin.types :as t]))

(def modes
  "Section 6.1: \"fan-out\" is not one answer but four. In a language with
  asynchrony, \"call every binding\" hides a decision - start them all and
  wait, await each in turn, or do not wait - and a design that leaves it
  unsaid gets four different answers from four ports, in the concurrency
  behaviour of production code no corpus entry happens to cover.

  Clojure has `pmap` and `future` right there, and using either for `emit`
  would make every hook point concurrent and every ordering assertion a
  race. The host stays sequential (section 5.2) and the modes stay data."
  ["emit" "parallel" "serial" "bail"])

(defn point-emit
  "Fan-out. Return values are ignored except in `bail`."
  [bindings mode arg]
  (cond
    (= "bail" mode)
    ;; Stops at the first binding that RETURNS A VALUE - the "handled,
    ;; stop" case. A `nil` RETURN DECLINES (section 6.1): clojure has one
    ;; way to say nothing, and the model's rule is written to that rather
    ;; than to JavaScript's null/undefined pair. `some?`, NOT truthiness -
    ;; `false` is a value.
    (first (keep #((:fn %) nil arg) bindings))

    ;; `emit` raises synchronously; the collecting modes gather.
    (= "emit" mode)
    (do (doseq [b bindings] ((:fn b) nil arg)) nil)

    :else
    (vec (keep (fn [b] (try ((:fn b) nil arg) nil
                            (catch Exception e (t/message-of e))))
               bindings))))

(defn compose
  "Composition: b1(b2(b3(base))), FIRST BINDING OUTERMOST (section 6.2).

  Recomputed by the host whenever the live set changes, and cached between
  changes. Plugins receive `next` as an argument; they never see or store
  the previous value of anything. A plugin that stashes `next` and calls
  it after deactivation is a bug the host cannot prevent, and this says so
  rather than pretending otherwise."
  [bindings base]
  (reduce (fn [inner b] (fn [arg] ((:fn b) inner arg)))
          base
          (reverse bindings)))

(defn point-provider
  "At most one live implementation (section 6.3). The winner is the highest
  band, ties broken by ref sort, and THE LOSERS ARE VISIBLE rather than
  silently ignored."
  [bindings spec]
  (if (empty? bindings)
    {:winner nil :shadowed []}
    (do
      (when (and (t/truthy (t/get spec "exclusive")) (< 1 (count bindings)))
        (let [refs (sort (map :ref bindings))]
          (t/fail "plugin_point_exclusive"
                  (str "point is exclusive and has " (count bindings) " bindings: "
                       (clojure.string/join ", " refs))
                  {"refs" (vec refs)})))
      (let [ranked (t/stable-sort-by (fn [b] [(- (:band b)) (:ref b)]) bindings)]
        {:winner (first ranked) :shadowed (vec (map :ref (rest ranked)))}))))
