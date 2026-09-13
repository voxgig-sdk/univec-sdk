;; VENDORED: @voxgig/plugin sdk-20260908-1556-0 (clojure/src/voxgig/plugin/config.clj)
;; Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
(ns voxgig.plugin.config
  "The declarative document (section 9): normalization, and the ten-level
  precedence ladder.

  TWO FUNCTIONS, AND THE SPLIT BETWEEN THEM IS FORCED.

  `normalize-config` normalizes STRUCTURE and ENTRY KEYS. It does not
  merge options, and cannot: section 9.4 makes merge behaviour a property
  of the definition's option SHAPE, which normalization has never seen. A
  normalizer that flattened the option layers would make `$MERGE: append`
  unimplementable at load time, because the layers it must concatenate
  would already be collapsed.

  `resolve-options` applies the ladder, and it is the only place that
  knows the shape."
  (:require [voxgig.plugin.types :as t]
            [voxgig.plugin.ref :as r]))

(def ^:private merge-words #{"replace" "append"})

(defn- pick
  "PRESENCE decides, not truthiness and not nil. A JSON `null` is a present
  value in JavaScript (`undefined !== null`), so it must be one here."
  [src k dflt]
  (if (t/has? src k) (t/get src k) dflt))

(defn- entries
  "Both document forms reduce to {ref -> entry} plus the order the form
  implies: array POSITION for the array form, sorted refs for the map
  form."
  [src]
  (cond
    (nil? src) {:map {} :order []}

    (sequential? src)
    {:map (reduce #(assoc %1 (r/canon-ref (t/get %2 "ref")) %2) {} src)
     :order (vec (map #(r/canon-ref (t/get % "ref")) src))}

    :else
    ;; Map-form refs arrive as KEYS, through a different path than an array
    ;; element's `ref` field - and must canonicalize the same way.
    (let [m (reduce #(assoc %1 (r/canon-ref %2) (src %2)) {} (t/sorted-keys src))]
      ;; Byte-wise, NOT locale-aware and NOT case-folded. All-lowercase
      ;; refs sort identically under all three, so only mixed input
      ;; discriminates: '@' is 0x40, uppercase 0x41-0x5A, lowercase
      ;; 0x61-0x7A. Clojure's `compare` on strings is String.compareTo,
      ;; which is exactly that.
      {:map m :order (vec (sort (keys m)))})))

(defn- check-reserved [ref reserved]
  (when (some #(= % (r/ref-name ref)) reserved)
    (t/fail "plugin_ref_reserved" (str "ref is reserved by the host: " ref) {"ref" ref})))

(defn normalize-config [input]
  (let [doc (or (t/get input "doc") {})
        keys- (or (t/get input "keys") {})
        ikey (or (t/get keys- "instance") "instance")
        dkey (or (t/get keys- "default") "default")
        reserved (or (t/get input "reserved") [])
        profile (t/get input "profile")
        ;; The rename is applied at TWO PLACES AND NO OTHERS: the document
        ;; root, and every profile.<name> overlay root (section 9.1). A
        ;; rename applied only at the root would leave `profile.prod.sdk`
        ;; untranslated and silently drop every environment override the
        ;; host depends on. Recursing further would be worse: option data
        ;; is the definition's.
        basedef (or (t/get doc dkey) {})
        overlay (let [o (when profile (t/get (t/get doc "profile") profile))]
                  (if (map? o) o {}))
        overdef (or (t/get overlay dkey) {})
        base (entries (t/get doc ikey))
        over (entries (t/get overlay ikey))]

    (doseq [group [(keys (:map base)) (keys (:map over))
                   (keys basedef) (keys overdef)]
            ref group]
      (check-reserved ref reserved))

    ;; A PARTIAL ARRAY IS NOT A FILTER (section 9.1). sdkgen learned this
    ;; the hard way: deriving order from a partial array silently dropped
    ;; config-activated features. Refs in the base but absent from the
    ;; overlay still load, in sorted position AFTER the listed ones. A
    ;; profile may also INTRODUCE a ref the base never declared. The
    ;; remainder keeps the BASE's own order.
    (let [order (vec (distinct (concat (:order over) (:order base))))
          instance
          (into {}
                (map-indexed
                 (fn [i ref]
                   (let [b ((:map base) ref)
                         o ((:map over) ref)
                         ;; MERGE THE ENTRIES AS AUTHORED, THEN APPLY
                         ;; DEFAULTS TO THE RESULT (section 9.3). A safety
                         ;; rule, not a tidiness one: if the overlay had
                         ;; its defaults filled in before merging it would
                         ;; carry a synthesized active:true and overwrite a
                         ;; base's false - silently re-enabling a
                         ;; deliberately disabled integration in
                         ;; production.
                         block (pick o "order" (pick b "order" nil))
                         nm (r/ref-name ref)
                         ;; Option layers, levels 3-6, IN LADDER ORDER.
                         ;; Never merged here.
                         layers (vec (for [src [(t/get basedef nm) b (t/get overdef nm) o]
                                           :when (t/has? src "options")]
                                       (t/get src "options")))
                         ent {"pos" i
                              "active" (pick o "active" (pick b "active" true))
                              "start" (pick o "start" (pick b "start" "eager"))
                              "optionlayers" layers}]
                     [ref (if (nil? block) ent (assoc ent "order" block))]))
                 order))]
      {"instance" instance
       "order" order
       ;; `default` DECLARES NOTHING (section 9.3). It is a base for every
       ;; instance of that definition; it does not create one, and an entry
       ;; for a name with no instances is inert rather than an error -
       ;; which is what makes a shared library of defaults shippable.
       "default" (merge basedef overdef)})))

;; --- resolve-options: section 9.3's ten levels, and 9.4's directives --

(defn check-shape
  "Section 9.4: N is an integer of at least 1, and everything else is an
  error.

  `{\"deep\": 0}` is rejected DESPITE having an obvious reading, because
  \"replace at this key\" already has a spelling and two spellings for one
  behaviour is the defect class this repo exists to avoid."
  [shape]
  (when (map? shape)
    (doseq [k (t/sorted-keys shape)
            :let [v (t/get shape k)]
            :when (and (map? v) (t/has? v "$MERGE"))]
      (let [directive (t/get v "$MERGE")]
        (cond
          (and (string? directive) (contains? merge-words directive)) nil

          (and (map? directive) (t/has? directive "deep")
               (let [n (t/get directive "deep")]
                 ;; `(integer? true)` is false in clojure, so the boolean
                 ;; case falls out for free here - unlike python, where it
                 ;; does not.
                 (and (integer? n) (<= 1 n))))
          nil

          :else
          (t/fail "plugin_shape_invalid"
                  (str "invalid $MERGE directive at " k ": " (t/encode directive))
                  {"key" k "directive" directive}))))))

(defn- defaults-of
  "The shape's non-directive values are the level-1 defaults."
  [shape]
  (into {} (for [k (t/sorted-keys shape)
                 :let [v (t/get shape k)]
                 :when (not (and (map? v) (t/has? v "$MERGE")))]
             [k v])))

(defn- opts-of [src k]
  (cond
    (nil? src) nil
    ;; The array form is equivalent to the map form (section 9.1).
    (sequential? src) (some #(when (= k (r/canon-ref (t/get % "ref"))) (t/get % "options")) src)
    :else (some #(when (= k (r/canon-ref %))
                   (let [entry (t/get src %)]
                     (when (map? entry) (t/get entry "options"))))
                (t/sorted-keys src))))

(declare merge-one)

(defn- deep-to
  "Merge N levels below this key, replace below that."
  [base over n]
  (if (or (<= n 0) (not (and (map? base) (map? over))))
    over
    (reduce (fn [acc k] (assoc acc k (deep-to (t/get acc k) (t/get over k) (dec n))))
            base
            (t/sorted-keys over))))

(defn- merge-one
  "Merge ONE layer onto the accumulator, honouring the shape's directives.
  The directive holds at EVERY precedence level, not only between document
  levels - section 9.4 makes it a property of the shape, which does not
  know which layer a value arrived from."
  [base over shape]
  (cond
    (nil? over) base
    (not (and (map? base) (map? over))) over
    :else
    (reduce
     (fn [acc k]
       (let [o (t/get over k)
             b (t/get acc k)
             directive (when (map? (t/get shape k)) (t/get (t/get shape k) "$MERGE"))]
         (cond
           (= "replace" directive) (assoc acc k o)
           (= "append" directive)
           (assoc acc k (vec (concat (if (sequential? b) b [])
                                     (if (sequential? o) o [o]))))
           (and (map? directive) (t/has? directive "deep"))
           (assoc acc k (deep-to b o (t/get directive "deep")))
           ;; Library default: deep for maps, REPLACE for lists.
           ;; struct.merge is element-wise by index, which for option maps
           ;; is nearly always wrong - ["a"] over ["x","y","z"] yielding
           ;; ["a","y","z"] is the defect station hit on
           ;; secrets.providers.
           :else (assoc acc k (if (and (map? b) (map? o)) (merge-one b o nil) o)))))
     base
     (t/sorted-keys over))))

(defn resolve-options [input]
  (let [shape (or (t/get input "shape") {})
        _ (check-shape shape)
        ref (r/canon-ref (t/get input "ref"))
        nm (r/ref-name ref)
        doc (or (t/get input "doc") {})
        profile (t/get input "profile")
        overlay (let [o (when profile (t/get (t/get doc "profile") profile))]
                  (if (map? o) o {}))]
    ;; ONE ordered merge, lowest to highest. Levels 3-6 are not two
    ;; namespaces collapsed separately and composed afterwards: that
    ;; inverts the rule that PROFILE SPECIFICITY OUTRANKS DEFINITION
    ;; SPECIFICITY, so a prod per-definition default would lose to a base
    ;; instance value.
    (reduce #(merge-one %1 %2 shape)
            {}
            [(defaults-of shape)                            ; 1
             (t/get input "hostdefaults")                   ; 2
             (opts-of (t/get doc "default") nm)             ; 3
             (opts-of (t/get doc "instance") ref)           ; 4
             (opts-of (t/get overlay "default") nm)         ; 5
             (opts-of (t/get overlay "instance") ref)       ; 6
             (t/get input "env")                            ; 7
             (t/get input "hostoptions")                    ; 8
             (t/get input "loadoptions")                    ; 9
             (t/get input "patch")])))                      ; 10
