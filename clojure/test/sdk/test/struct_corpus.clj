;; Univec SDK - the shared struct corpus, driven by the VENDORED
;; @voxgig/omni engine.
;;
;; The corpus wiring (`run-all` and the walk subjects below) is unchanged: it
;; names each section of .sdk/test/test.json "struct" and hands omni the
;; subject that drives it through this SDK's own vendored voxgig.struct. What
;; changed is the ENGINE underneath - the hand-written entry loop, matcher and
;; error handling that used to live in this file are gone, replaced by the
;; vendored runner reached through sdk.test.omni. A hand-written matcher can
;; only ever check what its author thought of; the shared one is the same code
;; every other port is held to.
;;
;; Counting: omni raises on the first failing entry in a set rather than
;; recording per-entry results, so a green section counts its whole set and a
;; red one counts one failure and names the entry omni rejected.
;;
;; The count is what the ENGINE RAN, never the section's declared `set` size.
;; sdk.test.omni increments a counter inside the subject wrapper - the one
;; place only the engine reaches - and its `runsetflags` returns the delta
;; across the set; `run-set` records that many passes, and fails the section
;; outright when the delta does not match the set it handed over. A count
;; taken from the spec instead would print the same number for a working
;; engine and for one that was never called, which is worse than no number:
;; it reads as evidence. So an all-green run reports exactly the corpus's own
;; entry count BECAUSE the engine executed exactly those entries - if the
;; number falls, the corpus stopped running, which is the one thing this
;; suite exists to notice.
(ns sdk.test.struct-corpus
  (:require [voxgig.struct :as s]
            [sdk.test.omni :as omni]
            [clojure.string :as str])
  (:import [java.util LinkedHashMap ArrayList List Map]))

(def NULLMARK omni/NULLMARK)
(def UNDEFMARK omni/UNDEFMARK)
(def EXISTSMARK omni/EXISTSMARK)

(def ^:dynamic *results* nil)

;; The omni runpack for the section being driven, bound by run-corpus (and by
;; the primary suite, which shares this recording shape).
(def ^:dynamic *runner* nil)

(defn- record! [group name ok? msg]
  (swap! *results* update (if ok? :pass :fail) (fnil conj []) {:group group :name name :msg msg}))

(defn- setsize [node]
  (let [testset (when (s/ismap node) (.get ^Map node "set"))]
    (if (s/islist testset) (.size ^List testset) 0)))

;; A section whose `set` is PRESENT but empty runs nothing and raises nothing:
;; it would record no passes and leave the suite green, which is the same
;; silent stoppage wearing corpus clothes. omni's own strict mode refuses it
;; (`checkset`), with an `empty: true` opt-out for a section that means it;
;; the shared corpus declares no OMNI version, so it is lenient v0 and that
;; check never fires - the rule is applied here instead. A section with no
;; `set` at all is left to omni, whose message for it is the better one.
(defn- empty-set? [node]
  (let [testset (when (s/ismap node) (.get ^Map node "set"))]
    (boolean (and (s/islist testset)
                  (zero? (.size ^List testset))
                  (not (true? (.get ^Map node "empty")))))))

;; Drive one corpus section through the vendored engine.
;;
;; `flags` is the corpus-facing spelling ({"null" false}); omni's own is
;; keyword-keyed, and it takes the section label there too, so a failure names
;; the section rather than the runner.
(defn run-set
  ([group node subject] (run-set group node {} subject))
  ([group node flags subject]
   (cond
     (nil? *runner*)
     (record! group "section" false "no omni runner bound")

     (not (s/ismap node))
     ;; A missing section used to be skipped in silence, which is how a
     ;; renamed corpus section becomes a suite that tests nothing.
     (record! group "section" false "corpus section missing")

     (empty-set? node)
     (record! group "entries" false "corpus section has an empty set")

     :else
     (let [omniflags (cond-> {:name group}
                       (contains? flags "null") (assoc :null (boolean (get flags "null"))))
           n (setsize node)]
       (try
         ;; `ran` is the engine's own execution count for this set, not the
         ;; corpus's declared size: a section that reports fewer (or, with a
         ;; disconnected engine, none) fails here instead of counting the
         ;; entries nobody ran.
         (let [ran (long (or ((:runsetflags *runner*) node omniflags subject) 0))]
           (if (not= ran n)
             (record! group "entries" false
                      (str "the engine ran " ran " of the section's " n " entries"))
             (dotimes [_ ran] (record! group "entry" true nil))))
         (catch Throwable err
           (record! group "entry" false (or (ex-message err) (str err)))))))))

;; A section that is one case rather than a `set`: `in` in, `out` expected.
;; omni has no entry point for these, so the comparison is its own
;; `deepequal`, on values converted back into its model.
(defn run-single [group node actual-fn]
  (if-not (s/ismap node)
    (record! group "single" false "corpus section missing")
    (try
      (let [expected (.get ^Map node "out")
            actual (omni/->omni (actual-fn (omni/->struct (.get ^Map node "in"))))]
        (if (omni/deep-equal? expected actual)
          (record! group "single" true nil)
          (record! group "single" false
                   (str "Expected: " (omni/stringify expected) ", got: " (omni/stringify actual)))))
      (catch Throwable e (record! group "single" false (or (ex-message e) (str e)))))))

;; A struct-model map literal, for the inject/transform sections that build a
;; store or an injection descriptor by hand.
(defn- omap [& kvs]
  (let [m (LinkedHashMap.)]
    (doseq [[k v] (partition 2 kvs)] (.put m k v))
    m))

(defn- gp [^Map m & ks] (reduce (fn [acc k] (when (s/ismap acc) (.get ^Map acc k))) m ks))
(defn- vget [vin k] (when (s/ismap vin) (.get ^Map vin k)))
(defn- vhas [vin k] (and (s/ismap vin) (.containsKey ^Map vin k)))

(declare run-walk-log walk-copy-subject walk-depth-subject)

(def null-modifier omni/null-modifier)

(defn run-all [spec]
  (let [minor (gp spec "minor") walk (gp spec "walk") mergeS (gp spec "merge")
        getpathS (gp spec "getpath") injectS (gp spec "inject") transformS (gp spec "transform")
        validateS (gp spec "validate") selectS (gp spec "select")]

    (run-set "minor.isnode" (gp minor "isnode") s/isnode)
    (run-set "minor.ismap" (gp minor "ismap") s/ismap)
    (run-set "minor.islist" (gp minor "islist") s/islist)
    (run-set "minor.iskey" (gp minor "iskey") {"null" false} s/iskey)
    (run-set "minor.strkey" (gp minor "strkey") {"null" false} s/strkey)
    (run-set "minor.isempty" (gp minor "isempty") {"null" false} s/isempty)
    (run-set "minor.isfunc" (gp minor "isfunc") s/isfunc)
    (run-set "minor.clone" (gp minor "clone") {"null" false} s/clone)
    (run-set "minor.escre" (gp minor "escre") s/escre)
    (run-set "minor.escurl" (gp minor "escurl") s/escurl)
    (run-set "minor.stringify" (gp minor "stringify") {"null" false}
             (fn [vin] (if (vhas vin "val") (s/stringify (vget vin "val") (vget vin "max")) (s/stringify))))
    (run-set "minor.jsonify" (gp minor "jsonify") {"null" false}
             (fn [vin] (s/jsonify (vget vin "val") (vget vin "flags"))))
    (run-set "minor.getelem" (gp minor "getelem") {"null" false}
             (fn [vin] (let [alt (vget vin "alt")]
                         (if (nil? alt) (s/getelem (vget vin "val") (vget vin "key"))
                             (s/getelem (vget vin "val") (vget vin "key") alt)))))
    (run-set "minor.delprop" (gp minor "delprop")
             (fn [vin] (s/delprop (vget vin "parent") (vget vin "key"))))
    (run-set "minor.size" (gp minor "size") {"null" false} s/size)
    (run-set "minor.slice" (gp minor "slice") {"null" false}
             (fn [vin] (s/slice (vget vin "val") (vget vin "start") (vget vin "end"))))
    (run-set "minor.pad" (gp minor "pad") {"null" false}
             (fn [vin] (s/pad (vget vin "val") (vget vin "pad") (vget vin "char"))))
    (run-set "minor.pathify" (gp minor "pathify") {"null" false}
             (fn [vin] (if (vhas vin "path") (s/pathify (vget vin "path") (vget vin "from"))
                           (s/pathify s/NOARG (vget vin "from")))))
    (run-set "minor.items" (gp minor "items") s/items)
    (run-set "minor.getprop" (gp minor "getprop") {"null" false}
             (fn [vin] (let [alt (vget vin "alt")]
                         (if (nil? alt) (s/getprop (vget vin "val") (vget vin "key"))
                             (s/getprop (vget vin "val") (vget vin "key") alt)))))
    (run-set "minor.setprop" (gp minor "setprop")
             (fn [vin] (s/setprop (vget vin "parent") (vget vin "key") (vget vin "val"))))
    (run-set "minor.haskey" (gp minor "haskey") {"null" false}
             (fn [vin] (s/haskey (vget vin "src") (vget vin "key"))))
    (run-set "minor.keysof" (gp minor "keysof") s/keysof)
    (run-set "minor.join" (gp minor "join") {"null" false}
             (fn [vin] (s/join (vget vin "val") (vget vin "sep") (vget vin "url"))))
    (run-set "minor.typify" (gp minor "typify") {"null" false} s/typify)
    (run-set "minor.setpath" (gp minor "setpath") {"null" false}
             (fn [vin] (s/setpath (vget vin "store") (vget vin "path") (vget vin "val"))))
    (run-set "minor.filter" (gp minor "filter")
             (let [checkmap {"gt3" (fn [n] (> (nth n 1) 3)) "lt3" (fn [n] (< (nth n 1) 3))}]
               (fn [vin] (s/filter (vget vin "val") (get checkmap (vget vin "check"))))))
    (run-set "minor.typename" (gp minor "typename") s/typename)
    (run-set "minor.flatten" (gp minor "flatten")
             (fn [vin] (s/flatten (vget vin "val") (vget vin "depth"))))

    (run-walk-log "walk.log" (gp walk "log"))
    (run-set "walk.basic" (gp walk "basic")
             (fn [vin] (s/walk vin (fn [_k val _p path]
                                     (if (string? val)
                                       (str val "~" (str/join "." (map str (vec path))))
                                       val)))))
    (run-set "walk.copy" (gp walk "copy") walk-copy-subject)
    (run-set "walk.depth" (gp walk "depth") {"null" false} walk-depth-subject)

    (run-single "merge.basic" (gp mergeS "basic") (fn [in] (s/merge (s/clone in))))
    (run-set "merge.cases" (gp mergeS "cases") s/merge)
    (run-set "merge.array" (gp mergeS "array") s/merge)
    (run-set "merge.integrity" (gp mergeS "integrity") s/merge)
    (run-set "merge.depth" (gp mergeS "depth")
             (fn [vin] (s/merge (vget vin "val") (vget vin "depth"))))

    (run-set "getpath.basic" (gp getpathS "basic")
             (fn [vin] (s/getpath (vget vin "store") (vget vin "path"))))
    (run-set "getpath.relative" (gp getpathS "relative")
             (fn [vin] (let [dpath (vget vin "dpath")
                             dpath (when (string? dpath) (let [a (ArrayList.)] (doseq [x (.split ^String dpath "\\." -1)] (.add a x)) a))
                             injdef (omap "dparent" (vget vin "dparent") "dpath" dpath)]
                         (s/getpath (vget vin "store") (vget vin "path") injdef))))
    (run-set "getpath.special" (gp getpathS "special")
             (fn [vin] (s/getpath (vget vin "store") (vget vin "path") (vget vin "inj"))))
    (run-set "getpath.handler" (gp getpathS "handler")
             (fn [vin] (let [handler (fn [_inj val _ref _store] (if (s/isfunc val) (val) val))
                             store (omap "$TOP" (vget vin "store") "$FOO" (fn [& _] "foo"))]
                         (s/getpath store (vget vin "path") (omap "handler" handler)))))

    (run-single "inject.basic" (gp injectS "basic")
                (fn [in] (s/inject (s/clone (.get ^Map in "val")) (s/clone (.get ^Map in "store")))))
    (run-set "inject.string" (gp injectS "string")
             (fn [vin] (s/inject (vget vin "val") (vget vin "store")
                                 (omap "modify" null-modifier "extra" (vget vin "current")))))
    (run-set "inject.deep" (gp injectS "deep")
             (fn [vin] (s/inject (vget vin "val") (vget vin "store"))))

    (run-single "transform.basic" (gp transformS "basic")
                (fn [in] (s/transform (.get ^Map in "data") (.get ^Map in "spec") (.get ^Map in "store"))))
    (doseq [g ["paths" "cmds" "each" "pack" "ref"]]
      (run-set (str "transform." g) (gp transformS g)
               (fn [vin] (s/transform (vget vin "data") (vget vin "spec") (vget vin "store")))))
    (run-set "transform.modify" (gp transformS "modify")
             (fn [vin] (s/transform (vget vin "data") (vget vin "spec")
                                    (omap "modify" (fn [val key parent _inj]
                                                     (when (and (some? key) (some? parent) (string? val))
                                                       (s/setprop parent key (str "@" val))))
                                          "extra" (vget vin "store")))))
    (run-set "transform.format" (gp transformS "format") {"null" false}
             (fn [vin] (s/transform (vget vin "data") (vget vin "spec"))))
    (run-set "transform.apply" (gp transformS "apply")
             (fn [vin] (s/transform (vget vin "data") (vget vin "spec"))))

    (run-set "validate.basic" (gp validateS "basic") {"null" false}
             (fn [vin] (s/validate (vget vin "data") (vget vin "spec"))))
    (doseq [g ["child" "one" "exact"]]
      (run-set (str "validate." g) (gp validateS g)
               (fn [vin] (s/validate (vget vin "data") (vget vin "spec")))))
    (run-set "validate.invalid" (gp validateS "invalid") {"null" false}
             (fn [vin] (s/validate (vget vin "data") (vget vin "spec"))))
    (run-set "validate.special" (gp validateS "special")
             (fn [vin] (s/validate (vget vin "data") (vget vin "spec") (vget vin "inj"))))

    (doseq [g ["basic" "operators" "edge" "alts"]]
      (run-set (str "select." g) (gp selectS g)
               (fn [vin] (s/select (vget vin "obj") (vget vin "query")))))))


;; `walk.log` is a single case whose expectation is the log the walk emits.
;; The node arrives in omni's model, so it is converted before the vendored
;; struct walks it, and the log converted back before omni compares.
(defn run-walk-log [group node]
  (if-not (s/ismap node)
    (record! group "log" false "corpus section missing")
    (try
      (let [test-data (omni/->struct node)
            log (ArrayList.)
            walklog (fn [key val parent path]
                      (.add log (str "k=" (if (nil? key) (s/stringify) (s/stringify key))
                                     ", v=" (s/stringify val)
                                     ", p=" (if (nil? parent) (s/stringify) (s/stringify parent))
                                     ", t=" (s/pathify path)))
                      val)
            expected (gp node "out" "after")]
        (s/walk (.get ^Map test-data "in") walklog)
        (if (omni/deep-equal? expected (omni/->omni log))
          (record! group "log" true nil)
          (record! group "log" false
                   (str "Expected: " (omni/stringify expected)
                        ", got: " (omni/stringify (omni/->omni log))))))
      (catch Throwable e (record! group "log" false (or (ex-message e) (str e)))))))

(defn walk-copy-subject [vin]
  (let [cur (atom (doto (ArrayList.) (.add nil)))]
    (letfn [(walkcopy [key val _parent path]
              (if (nil? key)
                (do (reset! cur (doto (ArrayList.) (.add nil)))
                    (.set ^List @cur 0 (cond (s/ismap val) (LinkedHashMap.) (s/islist val) (ArrayList.) :else val))
                    val)
                (let [i (s/size path)
                      v (if (s/isnode val)
                          (let [^List c @cur]
                            (while (<= (.size c) i) (.add c nil))
                            (let [nv (if (s/ismap val) (LinkedHashMap.) (ArrayList.))]
                              (.set c (int i) nv) nv))
                          val)]
                  (s/setprop (.get ^List @cur (int (dec i))) key v)
                  val)))]
      (s/walk vin {:before walkcopy})
      (.get ^List @cur 0))))

(defn walk-depth-subject [vin]
  (let [state (atom {:top nil :cur nil})]
    (letfn [(copy [key val _parent _path]
              (if (or (nil? key) (s/isnode val))
                (let [child (if (s/islist val) (ArrayList.) (LinkedHashMap.))]
                  (if (nil? key)
                    (swap! state assoc :top child :cur child)
                    (do (s/setprop (:cur @state) key child)
                        (swap! state assoc :cur child))))
                (s/setprop (:cur @state) key val))
              val)]
      (s/walk (vget vin "src") {:before copy :maxdepth (vget vin "maxdepth")})
      (:top @state))))


;; Returns [pass fail failures]. Prints each failure.
(defn run-corpus [testfile]
  (let [runpack ((omni/make-runner testfile) "struct")]
    (binding [*results* (atom {:pass [] :fail []})
              *runner* runpack]
      (run-all (:spec runpack))
      (let [r @*results* np (count (:pass r)) nf (count (:fail r))]
        (doseq [f (:fail r)] (println "STRUCT-FAIL" (:group f) (:name f) "-" (:msg f)))
        [np nf (:fail r)]))))
