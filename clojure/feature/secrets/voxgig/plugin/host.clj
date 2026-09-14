;; VENDORED: @voxgig/plugin sdk-20260908-1556-0 (clojure/src/voxgig/plugin/host.clj)
;; Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
(ns voxgig.plugin.host
  "The host: the lifecycle state machine (section 5), extension points
  (section 6), and resource capture (section 8) - and the instance api
  (`Instance`) the definitions see.

  TWO RULES SHAPE EVERY FUNCTION BELOW.

  Transitions are SEQUENTIAL (section 5.2). One at a time, in call order,
  never interleaved; a transition triggered from inside a lifecycle
  callback is `plugin_reentrant`. A hard rule, because it is the only way
  the semantics can be identical in Go, in Ruby and in single-threaded
  JavaScript.

  Reconciliation is EAGER (section 18's portability budget). A transition
  settles by running the state machine to a fixed point, not by suspending
  on a promise.

  ONE NAMESPACE FOR HOST AND INSTANCE, unlike every other port's two
  files. `Instance` calls back into the host and the host constructs `Instance`,
  and clojure namespaces cannot be circular; splitting them would need a
  protocol whose only purpose is to break a cycle that does not exist in
  the design.

  THE REGISTRY IS AN ATOM, and it is the one mutable thing in the port.
  Two consequences are worth stating plainly, because both are easy to get
  wrong and neither is visible from a green corpus.

  CALLBACKS NEVER RUN INSIDE `swap!`. `swap!` RETRIES its function under
  contention, so a callback run there could execute twice; and a callback
  that called back into its own host would be reading the atom it is
  mid-update on. Every function here computes outside and writes with a
  short, pure, targeted `swap!`.

  NEVER WRITE BACK A WHOLE SNAPSHOT. A callback mutates the registry while
  it runs, so the entry read before running one is stale afterwards. Every
  internal function takes a REF, not an entry."
  (:refer-clojure :exclude [list load apply declare])
  (:require [voxgig.plugin.types :as t]
            [voxgig.plugin.ref :as r]
            [voxgig.plugin.catalog :as cat]
            [voxgig.plugin.config :as config]
            [voxgig.plugin.capability :as cap]
            [voxgig.plugin.depend :as dep]
            [voxgig.plugin.export :as export]
            [voxgig.plugin.order :as ord]
            [voxgig.plugin.point :as pt]
            [clojure.string :as str]))

(deftype Host [state])
(deftype Instance [host ref])

(clojure.core/declare activate deactivate load unload reconcile! cascade! close
                      positionof order chosen exports catalog-add!)

;; --- the atom, and the only four ways this namespace touches it ------

(defn- snap [^Host h] @(.state h))
(defn- edit! [^Host h f] (swap! (.state h) f))
(defn- edit-vals! [^Host h f] (swap-vals! (.state h) f))
(defn- entry [h ref] (get-in (snap h) [:inst ref]))

(defn entry-update! [h ref f] (edit! h #(update-in % [:inst ref] f)))
(defn- set-field! [h ref k v] (entry-update! h ref #(assoc % k v)))
(defn- field [h ref k] (get-in (snap h) [:inst ref k]))
(defn- refs [h] (sort (keys (:inst (snap h)))))

(defn make-host
  ([] (make-host nil))
  ([options]
   (let [opts (or options {})]
     (->Host
      (atom {:opts opts
             :dependency (or (t/get opts "dependency") "restart")
             ;; Set for the duration of a bulk teardown, so `held` knows
             ;; this is a coordinated operation rather than an ad-hoc
             ;; deactivation.
             :coordinated false
             :catalog (or (t/get opts "catalog") (cat/make-catalog))
             :reserved (or (t/get opts "reserved") [])
             :points (or (t/get opts "points") {})
             :inst {}
             :log []
             ;; Section 14: the lifecycle event record. `seq` distinguishes
             ;; ONE INCARNATION of stripe$test from the next, which is the
             ;; whole reason it is not `pos` (section 4 rule 4).
             :events []
             :seqn 0
             :open 0
             :scopeid 0
             :intransition false
             ;; WHICH callback is running, not merely that one is. Section
             ;; 8.1 puts resource capture in `activate` and 8.3 says
             ;; `release` outside `activate` is `plugin_release_scope` -
             ;; and `intransition` alone cannot tell `activate` from
             ;; `define`, so it admitted an acquire in `define` whose scope
             ;; `unload` would never unwind.
             :phase nil})))))

(defn intransition? [h] (:intransition (snap h)))
(defn phase [h] (:phase (snap h)))
(defn point? [h nm] (contains? (:points (snap h)) nm))
(defn catalog [h] (:catalog (snap h)))

(defn catalog-add!
  "Extend a LIVE host's catalog. The catalog is a value (see `catalog`), so
  a caller holding one just keeps the result of `cat/add`; this is for the
  one that holds a host instead. Validation runs HERE, outside the
  `swap!`, because `swap!` retries and a throwing update function is not
  something to retry."
  [h definition]
  (let [updated (cat/add (catalog h) definition)]
    (edit! h #(assoc % :catalog updated))
    nil))

(defn define [h definition] (catalog-add! h definition))

;; --- scope (section 8) ----------------------------------------------

(defn- scope-release!
  "Releasing POPS THE ENTRY BY ID, which is what makes it idempotent: a
  second call finds nothing and does nothing, and so does one made after
  the whole scope unwound."
  [h ref id]
  (let [[old _] (edit-vals!
                 h (fn [s]
                     (let [scope (get-in s [:inst ref "scope"] [])
                           hit (first (filter #(= id (:id %)) scope))]
                       (if (nil? hit)
                         s
                         (-> s
                             (update :open - (:open hit))
                             (assoc-in [:inst ref "scope"]
                                       (vec (remove #(= id (:id %)) scope))))))))
        hit (first (filter #(= id (:id %)) (get-in old [:inst ref "scope"] [])))]
    (when (and hit (:fn hit)) ((:fn hit)))
    nil))

(defn- scope-push! [h ref f message]
  (when (not= "activate" (phase h)) (t/fail "plugin_release_scope" message))
  (let [[old _] (edit-vals!
                 h (fn [s]
                     (-> s
                         (update :scopeid inc)
                         (update :open inc)
                         (update-in [:inst ref "scope"] conj
                                    {:id (:scopeid s) :fn f :open 1}))))
        id (:scopeid old)]
    (fn [] (scope-release! h ref id))))

(defn- scope-uncounted! [h ref f]
  (edit! h (fn [s]
             (-> s
                 (update :scopeid inc)
                 (update-in [:inst ref "scope"] conj {:id (:scopeid s) :fn f :open 0}))))
  nil)

(defn- unwind!
  "Bindings go live only when activation succeeds (section 8.1), so the
  teardown is the exact inverse: reverse order, always.

  Returns the errors the scope raised. Section 8.3: \"A failing release
  does not stop the rest. Every entry runs, in reverse order, whatever any
  of them does; the errors are collected and raised as one
  `plugin_release_failed`.\"

  A selection belongs to ONE activation (section 11.4). Leaving `live` by
  any door drops it, so the next activation ranks afresh - keeping it
  would make a consumer prefer a provider it never actually ran against."
  [h ref]
  (let [[old _] (edit-vals!
                 h (fn [s]
                     (let [scope (get-in s [:inst ref "scope"])]
                       (-> s
                           (update :open - (reduce + 0 (map :open scope)))
                           (assoc-in [:inst ref "scope"] [])
                           (assoc-in [:inst ref "selected"] {})))))]
    (vec (keep (fn [one]
                 (when (:fn one)
                   (try ((:fn one)) nil (catch Exception e e))))
               (reverse (get-in old [:inst ref "scope"]))))))

(defn- release-check!
  "Section 8.3: \"A failed release ends the instance in `failed`, exactly
  as a failed callback does (5.2) - a release that raised may have leaked,
  and an instance that may be holding resources it cannot account for must
  not be reactivated.\""
  [h ref errors]
  (when (seq errors)
    (set-field! h ref "status" "failed")
    (let [causes (mapv t/message-of errors)]
      (t/fail "plugin_release_failed"
              (str "release failed for " ref ": " (str/join "; " causes))
              {"ref" ref "cause" causes}))))

;; --- the instance api (what a definition's callbacks see) ------------
;;
;; Deliberately not the internal record: a plugin that could reach
;; `status` could also write it. THE INSTANCE IS A HANDLE, `{host, ref}`
;; and nothing else, so a callback always sees current values and there is
;; no snapshot to keep in sync. That is this port's whole answer to the
;; canonical's "REFILL rather than REBIND" (section 9.6).

(defn inst-ref [^Instance i] (.ref i))
(defn inst-host [^Instance i] (.host i))
(defn inst-name [^Instance i] ((r/parse-ref (.ref i)) "name"))
(defn inst-tag [^Instance i] ((r/parse-ref (.ref i)) "tag"))
(defn inst-options [^Instance i] (field (.host i) (.ref i) "options"))
(defn inst-state [^Instance i] (field (.host i) (.ref i) "state"))

(defn state-put!
  "The state map is a VALUE here, so a callback cannot mutate what it
  reads; this is the write. Every other port spells it `i.state[k] = v`
  because its maps are objects."
  [^Instance i k v]
  (entry-update! (.host i) (.ref i) #(assoc-in % ["state" k] v))
  nil)

(defn state-update! [^Instance i k dflt f]
  (state-put! i k (f (or (t/get (inst-state i) k) dflt))))

(defn release!
  "Foreign resources the host did not hand out are registered explicitly
  (section 8.3); host calls are recorded automatically.

  SYMMETRIC WITH `acquire!`, and it has to be: `open` counts the resources
  CURRENTLY HELD, so an entry that is registered and then unwound must
  leave the count where it found it.

  Section 8.3: \"`inst.release` outside `activate` is
  `plugin_release_scope`\". A scope entry registered in `define` is never
  unwound, so \"in a transition\" is not the test - the PHASE is."
  [^Instance i f]
  (scope-push! (.host i) (.ref i) f "release called outside activate"))

(defn acquire!
  "The synthetic counter the driver owns, so \"what is open\" is data
  rather than an assertion each port words differently.

  Returns its own release, so a plugin can hand one back early. The scope
  still holds the entry and unwinding it twice is a no-op - releasing
  early must not make teardown wrong."
  [^Instance i]
  (scope-push! (.host i) (.ref i) nil "acquire called outside activate"))

(defn bind!
  "Bind into a host point. Declared in `define`; the host inserts it only
  after `activate` returns successfully (section 8.1), which is why a
  failing activate leaves no live binding behind.

  Section 12 has carried `plugin_bind_scope` - \"binding declared outside
  `define`\" - since before anything raised it, and it was the half nobody
  wrote: a binding added from `activate` went live without being part of
  the loaded definition, and a deactivate/activate cycle appended it
  again."
  ([i point f] (bind! i point f nil))
  ([^Instance i point f band]
   (let [h (.host i) ref (.ref i)]
     (when (not= "define" (phase h))
       (t/fail "plugin_bind_scope" (str "bind called outside define: " point)
               {"ref" ref "point" point}))
     (when-not (point? h point)
       (t/fail "plugin_point_unknown" (str "no such point: " point) {"point" point}))
     (entry-update! h ref #(update % "bindings" conj
                                   {:ref ref :point point :fn f :band (or band 0)}))
     nil)))

(defn export!
  "Published for other plugins and for the application (section 11)."
  [^Instance i k v]
  (entry-update! (.host i) (.ref i) #(assoc-in % ["exports" k] v))
  nil)

(defn provides!
  "What this instance can do for others (section 11.1)."
  [^Instance i prov]
  (entry-update! (.host i) (.ref i) #(update % "provides" conj prov))
  nil)

(defn position
  "Where this binding landed (section 6.6) - the plugin-side counterpart to
  a host pin. THE HOST DOES NOT POLICE THIS; it just makes the fact
  available. Verification tells a plugin it was misplaced; a pin (section
  7) stops the misplacement from being expressible at all. The two are not
  substitutes."
  [^Instance i point]
  (positionof (.host i) (.ref i) point))

(defn nest!
  "AN INSTANCE MAY ITSELF BE A HOST (section 6.5), and THE OUTER ONE OWNS
  THE INNER ONE'S LIFETIME. Registering the teardown in the instance scope
  is what makes that true rather than aspirational."
  ([i] (nest! i nil))
  ([^Instance i nestopts]
   (let [h (.host i) ref (.ref i)]
     (when-not (intransition? h)
       (t/fail "plugin_release_scope" "nest called outside a lifecycle callback"))
     (let [inner (make-host nestopts)]
       ;; NOT through `scope-push!`: a nested host is not a counted
       ;; resource, and `open` must read the same before and after one is
       ;; created.
       (scope-uncounted! h ref (fn [] (close inner)))
       (entry-update! h ref #(assoc % "inner" inner))
       inner))))

;; --- observation ----------------------------------------------------

(defn list
  "Introspection NEVER advances the state (section 5.2). A status page must
  not be a way to accidentally import twenty packages."
  [h]
  (into {} (for [[ref e] (:inst (snap h))] [ref (e "status")])))

(defn instance [h ref] (entry h (r/canon-ref ref)))

(defn trace [h] (vec (:events (snap h))))

(defn observable
  ([h] (observable h nil))
  ([h result]
   (let [s (snap h)]
     {"status" (into {} (for [[ref e] (:inst s)] [ref (e "status")]))
      "open" (:open s)
      "log" (vec (:log s))
      "result" result})))

;; --- the state machine ----------------------------------------------

(defn- guard [h]
  (when (intransition? h)
    (t/fail "plugin_reentrant" "transition attempted from inside a lifecycle callback")))

(defn- need [h ref]
  (let [rf (r/canon-ref ref)
        e (entry h rf)]
    (when (nil? e)
      (t/fail "plugin_not_loaded" (str "no such instance: " rf) {"ref" rf}))
    e))

(defn- check-reserved [h ref]
  (when (some #(= % (r/ref-name ref)) (:reserved (snap h)))
    (t/fail "plugin_ref_reserved" (str "ref is reserved by the host: " ref) {"ref" ref})))

(defn- invoke! [h ref f at]
  (edit! h #(assoc % :intransition true :phase at))
  (try
    (f (->Instance h ref))
    (catch Exception e
      ;; Section 12: `plugin_define_failed` and its three siblings are "a
      ;; callback raised; wraps the cause". AN ERROR THAT ALREADY CARRIES A
      ;; CODE KEEPS IT - the code is the error's identity, and a plugin
      ;; raising `store_unreachable` must not have it rewritten. Only a
      ;; code-less error is wrapped.
      (if (not= "" (t/code-of e))
        (throw e)
        (t/fail (str "plugin_" at "_failed")
                (str ref " raised in " at ": " (t/message-of e))
                {"ref" ref "cause" (t/message-of e)})))
    (finally (edit! h #(assoc % :intransition false :phase nil)))))

(defn- run-callback! [h ref callback at]
  (let [e (entry h ref)
        f (t/get (e "def") callback)]
    (edit! h (fn [s]
               (-> s
                   (update :log conj (str ref ":" at))
                   (update :events conj {"ref" ref "event" at
                                         "seq" (e "seq") "status" (e "status")}))))
    (when (fn? f) (invoke! h ref f at))
    nil))

(defn- autotag
  "AUTO-TAGGING IS EXPLICIT (section 4 rule 3). `(declare h \"stripe\"
  {\"tag\" \"?\"})` assigns the LOWEST UNUSED POSITIVE INTEGER tag and
  returns the assigned pair. Without `\"?\"`, a collision is an error."
  [h nm]
  (let [taken (:inst (snap h))]
    (first (for [n (iterate inc 1)
                 :let [cand (r/format-ref nm (str n))]
                 :when (not (contains? taken cand))]
             cand))))

(defn- new-entry! [h rf spec definition]
  (let [pos (t/get spec "pos")
        [old _] (edit-vals!
                 h (fn [s]
                     (-> s
                         (update :seqn inc)
                         (assoc-in [:inst rf]
                                   {"ref" rf "def" definition "status" "declared"
                                    "pos" (if (nil? pos) (count (:inst s)) pos)
                                    "seq" (:seqn s)
                                    "options" (or (t/get spec "options") {})
                                    "state" {} "order" (t/get spec "order")
                                    "unmet" [] "scope" []
                                    ;; Section 11.4's ALWAYS-RELUCTANT
                                    ;; rebinding made concrete: the
                                    ;; provider ref this instance's
                                    ;; activation actually chose, per
                                    ;; requirement name. Re-ranking on
                                    ;; every question silently re-points a
                                    ;; live consumer at any better
                                    ;; newcomer, and then losing the
                                    ;; provider it was really using does
                                    ;; not restart it.
                                    "selected" {} "bindings" []
                                    "exports" {} "provides" []
                                    "inner" nil "barred" false}))))]
    (entry h rf)))

(defn declare
  ([h ref] (declare h ref nil))
  ([h ref spec]
   (let [spec (or spec {})
         ref (if (= "?" (t/get spec "tag"))
               (autotag h (r/ref-name (r/canon-ref ref)))
               ref)
         rf (r/canon-ref ref)]
     (when-not (t/truthy (t/get spec "hostowned")) (check-reserved h rf))
     (let [defname (or (t/get spec "definition") (r/ref-name rf))
           definition (cat/definition-of (catalog h) defname)]
       (when (nil? definition)
         (t/fail "plugin_unknown_definition" (str "not in catalog: " defname)
                 {"name" defname}))
       (let [existing (entry h rf)]
         (cond
           (nil? existing) (new-entry! h rf spec definition)
           ;; Section 4 rule 1: a pair addresses at most one instance.
           ;; Re-declaring the SAME definition is the idempotent case; a
           ;; different one is a duplicate, not a silent overwrite (seneca)
           ;; and not an impossibility (sdkgen).
           (not= (t/get (existing "def") "name") (t/get definition "name"))
           (t/fail "plugin_ref_duplicate" (str "instance already declared: " rf)
                   {"ref" rf})
           :else existing))))))

(defn hostdeclare
  "Section 9.1: a host that reserves a name MUST still be able to declare
  the instance it reserved - \"The host declares those instances itself,
  after the user merge, and always wins.\"

  THE BOUNDARY IS BY FUNCTION, NOT BY CALLER, and that is a real limit: no
  language here can tell the embedding host from a plugin holding the same
  host value. What reservation protects is CONFIGURATION - documents,
  overlays, `VOXGIG_PLUGIN_*`, construction options and ordinary
  declare/load/options - and all of that still checks."
  ([h ref] (hostdeclare h ref nil))
  ([h ref spec]
   (guard h)
   (declare h ref (assoc (or spec {}) "hostowned" true))))

;; The requirement graph as plain data, for the pure detector.
(defn- graph-nodes [h]
  (let [s (snap h)]
    (vec (for [rf (sort (keys (:inst s)))
               :let [e (get-in s [:inst rf])]]
           {:ref rf
            :provides (mapv #(t/get % "name") (e "provides"))
            :requires (dep/requirements (e "options"))}))))

;; A step whose failure lands the instance in `failed` and re-raises.
(defn- stage! [h ref f]
  (try (f)
       (catch Exception e (set-field! h ref "status" "failed") (throw e))))

(defn load
  ([h ref] (load h ref nil))
  ([h ref spec]
   (guard h)
   (let [spec (or spec {})
         e (declare h ref spec)
         rf (e "ref")]
     (if (not= "declared" (e "status"))
       ;; Idempotent trivially.
       e
       (do
         (when-let [options (t/get spec "options")] (set-field! h rf "options" options))
         (stage! h rf #(run-callback! h rf "define" "define"))
         (set-field! h rf "status" "loaded")
         ;; AT LOAD, and before anything runs: a cycle through
         ;; restart-causing requirements does not settle, and the only safe
         ;; time to report a non-terminating reconcile is before it starts
         ;; (section 11.3). `provides` is populated by `define`, which has
         ;; just run, so this is the first moment the graph is complete.
         (stage! h rf #(dep/check-cycle (graph-nodes h)))
         (entry h rf))))))

;; --- dependencies ---------------------------------------------------

(defn- providers-of [h req]
  (let [nm (t/get req "name")
        want (r/canon nm)
        s (snap h)
        cands (vec (for [rf (sort (keys (:inst s)))
                         :let [target (get-in s [:inst rf])]
                         :when (= "live" (target "status"))
                         c (if (= rf want)
                             ;; A ref satisfies directly.
                             [{"ref" rf "pos" (target "pos") "provides" {"name" nm}}]
                             (for [prov (target "provides")
                                   :when (= nm (t/get prov "name"))]
                               {"ref" rf "pos" (target "pos") "provides" prov}))]
                     c))]
    (cap/resolve-capability req cands)))

(defn- unmet-of
  "A REQUIREMENT IS ON A CAPABILITY, not on a ref (section 11.1). A bare
  string is shorthand for `{name}`. A ref satisfies too, because a host
  that genuinely needs a specific instance should not have to invent a
  capability for it."
  [h ref]
  (vec (for [req (dep/requirements (field h ref "options"))
             :when (dep/gates-activation? req)
             :when (empty? (providers-of h req))]
         (t/get req "name"))))

(defn- chosen
  "Section 11.4's always-reluctant selection, and the ONE place a provider
  is picked for a live instance. If this instance already selected a
  provider for `req` and that provider is STILL a candidate, it keeps it -
  a better-ranked newcomer does not take it.

  `remember` is false for the questions asked ABOUT an instance rather
  than BY it: introspection must not create a binding."
  [h ref req remember]
  (let [cands (providers-of h req)
        nm (t/get req "name")
        held (t/get (field h ref "selected") nm)]
    (cond
      (empty? cands) nil
      (and (some? held) (some #(= held (t/get % "ref")) cands)) held
      :else
      (let [pick (t/get (first cands) "ref")]
        (when remember (entry-update! h ref #(assoc-in % ["selected" nm] pick)))
        pick))))

(defn- bound-providers
  "The instances currently SELECTED for this one's restart-causing
  requirements. A BINDING IS TO AN INSTANCE, not to a capability (section
  11.1): the selected one going away restarts a `static` consumer even
  though a survivor is available."
  [h ref]
  (->> (dep/requirements (field h ref "options"))
       (filter dep/restarts-on-loss?)
       (map #(chosen h ref % false))
       (remove nil?)
       distinct
       set))

(defn- consumers-of
  "Live instances whose selected provider is `ref` and which would be
  restarted by losing it."
  [h ref]
  (filterv #(and (not= % ref)
                 (= "live" (field h % "status"))
                 (contains? (bound-providers h %) ref))
           (refs h)))

(defn- holders-of
  "Section 11.3's `hold` asks a DIFFERENT question from the cascade, and
  reading it off `consumers-of` answered the cascade's.

  The cascade wants the edges that RESTART - mandatory-static and
  optional-static - because a restart is what it performs. `hold` says
  \"deactivating a REQUIRED instance is `plugin_dependency_held`\", and
  required is cardinality: `gates-activation?`, not `restarts-on-loss?`.
  The two sets differ in both directions and each difference was a real
  bug.

  A MANDATORY-DYNAMIC consumer was excluded, so the strictest policy let a
  provider go that a live consumer could not do without - `dynamic`
  promises survival of a SWAP, and under `hold` there is no swap, so the
  consumer falls back to `pending`.

  An OPTIONAL-STATIC consumer was included, so `hold` refused a
  deactivation on behalf of an instance that had said in writing it does
  not need the thing."
  [h ref]
  (filterv (fn [rf]
             (and (not= rf ref)
                  (= "live" (field h rf "status"))
                  (boolean (some #(and (dep/gates-activation? %)
                                       (= ref (chosen h rf % false)))
                                 (dep/requirements (field h rf "options"))))))
           (refs h)))

(defn- held
  "The hold check is A GUARD ON AD-HOC DEACTIVATION, NOT ON COORDINATED
  TEARDOWN. In a bulk operation that is removing the holders too - `close`,
  or an `apply` plan whose own steps deactivate them - it is suspended for
  exactly those holders, and the teardown still runs consumers before
  providers."
  [h ref]
  (let [s (snap h)]
    (when (and (= "hold" (:dependency s)) (not (:coordinated s)))
      (let [holders (holders-of h ref)]
        (when (seq holders)
          (t/fail "plugin_dependency_held"
                  (str "instance is required by live consumers: " ref)
                  {"ref" ref "holders" holders}))))))

(defn- failed? [f] (try (f) false (catch Exception _ true)))

(defn- demote!
  "Leaving `live` for `pending` - or for `failed`, because section 5.2 says
  ANY failure during a transition lands the instance there. Marking it
  `pending` handed it straight back to `reconcile`, which would activate it
  again the moment the provider returned."
  [h rf]
  (let [bad (failed? #(run-callback! h rf "deactivate" "deactivate"))
        errors (unwind! h rf)]
    (if (or bad (seq errors))
      (set-field! h rf "status" "failed")
      (do (set-field! h rf "status" "pending")
          (set-field! h rf "unmet" (unmet-of h rf))))))

(defn- cascade!
  "CONSUMERS GO DOWN FIRST, NOT AFTERWARDS (section 11.3).

  The cascade is part of the provider's own deactivation and runs BEFORE
  the provider's `deactivate` callback and scope unwind, so a consumer's
  teardown can still call the thing it depends on - flushing a buffer to
  the store it is about to lose is exactly what a `deactivate` callback is
  for, and a cascade that fired after the provider was already gone would
  make that impossible."
  [h ref seen]
  (if (contains? seen ref)
    seen
    (reduce (fn [acc rf]
              (if (not= "live" (field h rf "status"))
                acc
                (let [acc (cascade! h rf acc)]   ; deepest-first
                  (demote! h rf)
                  acc)))
            (conj seen ref)
            (consumers-of h ref))))

;; The live half of leaving `live`: the callback, then the scope.
(defn- teardown! [h rf]
  (try
    (run-callback! h rf "deactivate" "deactivate")
    (catch Exception e (unwind! h rf) (set-field! h rf "status" "failed") (throw e)))
  (release-check! h rf (unwind! h rf)))

(defn- to-active! [h rf]
  ;; A declared requirement that is not live means `pending`: activation is
  ;; a STANDING REQUEST, not a one-shot event.
  (let [unmet (unmet-of h rf)]
    (if (seq unmet)
      (do (set-field! h rf "unmet" unmet)
          (set-field! h rf "status" "pending")
          (entry h rf))
      (do
        (try
          (run-callback! h rf "activate" "activate")
          (catch Exception e
            ;; Unwind whatever the partial activation captured, in reverse.
            (unwind! h rf)
            (set-field! h rf "status" "failed")
            (throw e)))
        ;; Section 11.4: THE SELECTION IS MADE HERE, once, and remembered.
        ;; Every later question - the cascade, `hold`, `unmet` - reads it
        ;; back rather than re-ranking, which is what "always-reluctant"
        ;; means.
        (doseq [req (dep/requirements (field h rf "options"))] (chosen h rf req true))
        (set-field! h rf "status" "live")
        (reconcile! h)
        (entry h rf)))))

(defn activate [h ref]
  (guard h)
  (let [e (need h ref)
        rf (e "ref")]
    (cond
      ;; A no-op returning success.
      (= "live" (e "status")) e
      (= "failed" (e "status"))
      (t/fail "plugin_bad_state" (str "instance has failed: " rf) {"ref" rf})
      ;; Section 9.6: `active: false` bars the instance from running, and
      ;; the bar is on the INSTANCE rather than on the apply that set it.
      ;; `ready` reaches this through `activate`, so one guard covers both
      ;; verbs the design names.
      (t/truthy (e "barred"))
      (t/fail "plugin_inactive" (str "instance is barred by active: false: " rf)
              {"ref" rf})
      :else (do (when (= "declared" (e "status")) (load h rf))
                (to-active! h rf)))))

(defn deactivate [h ref]
  (guard h)
  (let [e (need h ref)
        rf (e "ref")]
    (cond
      (contains? #{"loaded" "declared"} (e "status")) e
      ;; Section 5.2: `unload` is THE ONLY TRANSITION OUT OF `failed`.
      (= "failed" (e "status"))
      (t/fail "plugin_bad_state" (str "instance has failed: " rf) {"ref" rf})
      ;; DEACTIVATING A PENDING INSTANCE RUNS NO CALLBACK (section 5.2). It
      ;; never reached activate, so it holds no scope and no live bindings;
      ;; running the definition's deactivate there would be teardown
      ;; without matching setup, which plugins are not written to survive
      ;; and which could fail an instance that had done nothing wrong. It
      ;; cannot fail.
      (= "pending" (e "status"))
      (do (set-field! h rf "status" "loaded") (set-field! h rf "unmet" []) (entry h rf))
      :else
      (do (held h rf)
          (cascade! h rf #{})
          (teardown! h rf)
          (set-field! h rf "status" "loaded")
          (reconcile! h)
          (entry h rf)))))

(defn unload [h ref]
  (guard h)
  (let [e (need h ref)
        rf (e "ref")]
    (when (contains? #{"live" "pending"} (e "status"))
      ;; Section 5.2: ANY failure during a transition lands the instance in
      ;; `failed`, with the scope STILL FULLY UNWOUND - and the instance
      ;; STAYS REGISTERED, because `failed` is a state an operator has to
      ;; be able to see.
      (when (= "live" (e "status"))
        (held h rf)
        (cascade! h rf #{})
        (teardown! h rf))
      (set-field! h rf "status" "loaded"))
    (if (contains? #{"loaded" "failed"} (field h rf "status"))
      (try (run-callback! h rf "close" "close")
           (finally (edit! h #(update % :inst dissoc rf))))
      (edit! h #(update % :inst dissoc rf)))
    nil))

(defn ready
  "Runs the whole forward path in one call (section 5.1)."
  [h ref]
  (guard h)
  (let [rf (r/canon-ref ref)]
    (when (nil? (entry h rf)) (declare h rf))
    (when (= "declared" (field h rf "status")) (load h rf))
    (activate h rf)))

;; --- reconciliation --------------------------------------------------

(defn- restartable?
  "POLICY IS PER REQUIREMENT, not per instance (section 11.3). A `dynamic`
  requirement whose provider is gone leaves the consumer LIVE and
  notified."
  [h rf]
  (boolean (some dep/restarts-on-loss?
                 (for [req (dep/requirements (field h rf "options"))
                       :when (dep/gates-activation? req)
                       :when (empty? (providers-of h req))]
                   req))))

(defn- loss-pass! [h]
  (reduce (fn [moved rf]
            (if (or (not= "live" (field h rf "status")) (not (restartable? h rf)))
              moved
              (do (demote! h rf) true)))
          false
          (refs h)))

(defn- gain-pass! [h]
  (reduce (fn [moved rf]
            (if (or (not= "pending" (field h rf "status")) (seq (unmet-of h rf)))
              moved
              (do (try
                    (run-callback! h rf "activate" "activate")
                    (set-field! h rf "status" "live")
                    (set-field! h rf "unmet" [])
                    (catch Exception _
                      (unwind! h rf)
                      (set-field! h rf "status" "failed")))
                  true)))
          false
          (refs h)))

(defn- reconcile!
  "EAGER reconciliation: run to a fixed point rather than scheduling.

  Two directions, and both are the reason `pending` exists. Activation is a
  STANDING REQUEST, not a one-shot event."
  [h]
  (loop [rounds 0]
    (when (>= 1000 rounds)
      ;; Losses first, so a cascade settles in one pass rather than
      ;; alternating with re-activations.
      (let [lost (loss-pass! h)
            gained (gain-pass! h)]
        (when (or lost gained) (recur (inc rounds)))))))

;; --- ordering --------------------------------------------------------

(defn order
  ([h] (order h nil))
  ([h point]
   (let [s (snap h)
         bindings (->> (keys (:inst s))
                       (filter #(= "live" (get-in s [:inst % "status"])))
                       ;; Sorted by declaration SEQUENCE, which is what
                       ;; makes the section 7 sort's fall-through
                       ;; deterministic in a language whose maps have no
                       ;; insertion order. Section 7 breaks ties by `pos`;
                       ;; two instances CAN share one - `declare` defaults
                       ;; `pos` to the registry size, so an unload followed
                       ;; by a fresh declare reuses a surviving instance's
                       ;; - and past that this was falling through to map
                       ;; order. `seq` is that order, made explicit.
                       (sort-by #(get-in s [:inst % "seq"]))
                       (mapv #(hash-map :ref % :pos (get-in s [:inst % "pos"])
                                        :order (get-in s [:inst % "order"]))))]
     (ord/resolve-order bindings (when point (t/get (get-in s [:points point]) "pin"))))))

;; --- points ----------------------------------------------------------

(defn- point-at [h point] (get-in (snap h) [:points point]))

(defn- bound
  "Live bindings on a point, in resolved order. Recomputed on any change to
  the live set (section 7) rather than cached at startup - the bug a host
  discovers only when something deactivates in production."
  [h point]
  (vec (for [rf (order h point)
             :let [e (entry h rf)
                   ;; The band is the INSTANCE's ordering block (section
                   ;; 7), stamped by the host. A plugin passing its own
                   ;; would be ranking itself above the order its document
                   ;; declared.
                   band (or (t/asint (t/get (or (e "order") {}) "band")) 0)]
             b (e "bindings")
             :when (= point (:point b))]
         (assoc b :band band))))

(defn- point-spec [h point want]
  (let [spec (point-at h point)]
    (when (nil? spec)
      (t/fail "plugin_point_unknown" (str "no such point: " point) {"point" point}))
    (let [kind (t/get spec "kind")]
      (cond
        ;; A point with no declared kind is a hook, which is what makes
        ;; `{}` the minimal point declaration.
        (and (= "hook" want) (or (nil? kind) (= "hook" kind))) spec
        (and (not= "hook" want) (= kind want)) spec
        :else (t/fail "plugin_point_kind" (str "point is not a " want ": " point)
                      {"point" point "kind" kind})))))

(defn emit
  ([h point] (emit h point nil))
  ([h point arg]
   (let [spec (point-spec h point "hook")]
     (pt/point-emit (bound h point) (or (t/get spec "mode") "emit") arg))))

(defn call
  ([h point] (call h point nil))
  ([h point arg]
   (let [spec (point-spec h point "chain")]
     ((pt/compose (bound h point) (or (t/get spec "base") identity)) arg))))

(defn provider
  ([h point] (provider h point nil))
  ([h point arg]
   (let [spec (point-spec h point "provider")
         pick (pt/point-provider (bound h point) spec)]
     (if (nil? (:winner pick))
       (t/get spec "default")
       ((:fn (:winner pick)) nil arg)))))

(defn shadowed
  "The losers are VISIBLE rather than silently ignored (section 6.3)."
  [h point]
  (let [spec (point-at h point)]
    (if (nil? spec) [] (:shadowed (pt/point-provider (bound h point) spec)))))

(defn exports [h spec]
  (let [s (snap h)]
    (export/resolve-export
     spec
     (vec (for [rf (sort (keys (:inst s)))
                :let [e (get-in s [:inst rf])]
                ;; Exports of a `loaded` (not live) instance are VISIBLE
                ;; (11).
                :when (not (contains? #{"declared" "failed"} (e "status")))
                k (t/sorted-keys (e "exports"))]
            {:ref rf :key k :value (get-in e ["exports" k])})))))

(defn capability
  "The live providers of a capability, best-first (section 11.1)."
  [h nm]
  (let [s (snap h)
        cands (vec (for [rf (sort (keys (:inst s)))
                         :let [e (get-in s [:inst rf])]
                         :when (= "live" (e "status"))
                         prov (e "provides")
                         :when (= nm (t/get prov "name"))]
                     {"ref" rf "pos" (e "pos") "provides" prov}))]
    (mapv #(t/get % "ref") (cap/resolve-capability {"name" nm} cands))))

;; --- documents -------------------------------------------------------

(defn- shape-of [h ref]
  (t/get (cat/definition-of (catalog h) (r/ref-name ref)) "shape"))

(defn- drop-phase!
  "Phase 1: deactivations and unloads, REVERSE load order."
  [h want-live?]
  (doseq [rf (->> (refs h)
                  (remove #(or (= "declared" (field h % "status")) (want-live? %)))
                  ;; Highest `pos` first, ref-descending for a tie, so a
                  ;; consumer declared after its provider goes down first.
                  (sort-by (fn [rf] [(- (field h rf "pos")) rf])
                           (fn [[pa a] [pb b]] (if (= pa pb) (compare b a) (compare pa pb)))))]
    (unload h rf)))

(defn- declare-phase!
  "Phase 2: declare and patch EVERYTHING, in load order."
  [h ref norm optionsof]
  (let [ent (t/get (norm "instance") ref)]
    (declare h ref {"options" (optionsof ref) "order" (t/get ent "order")
                    "pos" (t/get ent "pos")})
    (entry-update! h ref
                   #(merge % {;; The bar is REASSERTED ON EVERY APPLY, in
                              ;; both directions - a document that turns
                              ;; the instance back on clears it, which is
                              ;; the whole point of a config switch.
                              "barred" (not (t/truthy (t/get ent "active")))
                              "options" (optionsof ref)
                              "order" (t/get ent "order")
                              "pos" (t/get ent "pos")}))))

(defn apply
  "Section 9.6: \"load what is missing, UNLOAD WHAT IS GONE, patch what
  changed, and move activation state to match\", with the stated ordering -
  \"deactivations and unloads first (reverse load order), then loads, then
  activations in load order\".

  FOUR PHASES, NOT ONE INTERLEAVED LOOP. An earlier draft walked the
  document once, which never looked at instances the new document had
  DROPPED - so an integration removed from a config reload stayed live with
  its bindings and resources."
  ([h doc] (apply h doc nil))
  ([h doc profile]
   (guard h)
   (let [s (snap h)
         profile (or profile (t/get (:opts s) "profile"))
         norm (config/normalize-config {"doc" doc "profile" profile
                                        "keys" (t/get (:opts s) "keys")
                                        "reserved" (:reserved s)})
         want (norm "order")
         defaults (or (t/get (:opts s) "defaults") {})
         optionsof (into {} (for [ref want]
                              [ref (config/resolve-options
                                    {"ref" ref "doc" doc "profile" profile
                                     "shape" (shape-of h ref)
                                     "hostdefaults" (t/get defaults (r/ref-name ref))})]))
         ;; Should this ref be LIVE after the apply? False for a ref the
         ;; document declares lazy or inactive AND for one it does not name
         ;; at all - which is what makes "unload what is gone" and "unload
         ;; what was toggled off" one rule rather than two.
         want-live? (fn [ref]
                      (let [e (t/get (norm "instance") ref)]
                        (and (some? e) (t/truthy (t/get e "active"))
                             (= "eager" (t/get e "start")))))]
     (drop-phase! h want-live?)
     (doseq [ref want] (declare-phase! h ref norm optionsof))
     ;; ONLY THE EAGER, ACTIVE ONES: "a document of twenty lazy instances
     ;; is twenty map entries and no executed code" (9.6).
     (doseq [ref want :when (want-live? ref)] (load h ref))
     (doseq [ref want :when (want-live? ref)] (activate h ref))
     nil)))

(defn- reconfigure! [h rf definition resolved previous]
  (let [f (t/get definition "reconfigure")]
    (if (fn? f)
      (do (edit! h #(assoc % :intransition true))
          (try (f (->Instance h rf) resolved previous)
               (finally (edit! h #(assoc % :intransition false)))))
      ;; Always correct and sometimes expensive; `reconfigure` exists to
      ;; make the common case cheap (section 9.4).
      (do (deactivate h rf) (activate h rf)))))

(defn options [h ref patch]
  (guard h)
  (let [e (need h ref)
        rf (e "ref")
        previous (e "options")
        resolved (config/resolve-options {"ref" rf "shape" (shape-of h rf) "doc" {}
                                          "patch" (merge previous (or patch {}))})]
    (set-field! h rf "options" resolved)
    (when (= "live" (e "status")) (reconfigure! h rf (e "def") resolved previous))
    nil))

(defn close [h]
  ;; A bulk teardown removing the holders too, so `hold` is suspended for
  ;; exactly those holders (section 11.3) - while the consumers-first
  ;; cascade still runs, which is the half that matters.
  (edit! h #(assoc % :coordinated true))
  (try (doseq [rf (reverse (refs h))] (unload h rf))
       (finally (edit! h #(assoc % :coordinated false)))))

(defn positionof
  "The same record section 6.6 gives a plugin about itself, reachable from
  outside for the corpus."
  [h ref point]
  (let [e (entry h (r/canon ref))]
    (when (nil? e)
      (t/fail "plugin_not_loaded" (str "no such instance: " ref) {"ref" ref}))
    (let [ranked (order h point)
          index (or (first (keep-indexed #(when (= %2 (e "ref")) %1) ranked)) -1)]
      {"index" index
       "count" (count ranked)
       ;; Section 6.2 composes b1(b2(b3(base))) with the FIRST binding
       ;; OUTERMOST, so these are not index 0 and index count-1 the other
       ;; way round.
       "outermost" (zero? index)
       "innermost" (= index (dec (count ranked)))})))
