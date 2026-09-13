;; Univec SDK corpus test runner: the vendored @voxgig/omni engine driven
;; through its NATIVE API (`voxgig.omni.runner/make-runner`), presented to the
;; corpus suites in the runner shape they already use (`:spec`, `:runset`,
;; `:runsetflags`, `:client`). No compatibility shim is vendored: the adapter
;; below IS the whole bridge, per language, per the vendor-tag rollout
;; (docs/design/vendor-tag-rollout.md, Decision 4). It is the clojure peer of
;; tm/lua/test/omni.lua, tm/rb/test/omni.rb and tm/java/test/OmniResolver.java.
;;
;; Four local decisions, all required:
;;
;; 1. TWO VALUE MODELS, converted at the subject boundary. omni's clojure port
;;    speaks IMMUTABLE clojure data - `ismap` is `map?`, `islist` is `vector?`,
;;    absence is the `::u/absent` keyword. The SDK and the vendored struct
;;    speak MUTABLE JVM collections (java.util.LinkedHashMap / ArrayList),
;;    because struct's contract is that a utility MUTATES the node it is
;;    given. Neither recognises the other, so `wrap-subject` converts every
;;    argument on the way in (`->struct`) and the result on the way out
;;    (`->omni`).
;;
;; 2. NO-VALUE ARITY (the zero-argument correction the dynamic ports carry).
;;    An entry with no `in` must reach the subject as NO value, not as one
;;    null: the corpus has both `{in: null, out: <T_null>}` and
;;    `{out: <T_noval>}`, and a port that collapses them silently passes one
;;    of the two. omni models the absence as its ABSENT sentinel, and here it
;;    becomes a genuine ZERO-ARITY call whenever the subject HAS a zero-arity
;;    arm - `s/typify` is handed to the corpus bare, so `(typify)` answers
;;    T_noval where `(typify nil)` answers T_null.
;;
;;    A subject with no zero-arity arm gets `nil` instead. That fallback is
;;    not a convenience: struct's NOARG is TYPIFY's marker, not a general
;;    no-value, so handing it to a one-arity subject is simply a wrong
;;    argument - `(isempty NOARG)` answers false where the corpus wants the
;;    true that `(isempty nil)` gives, and `(clone NOARG)` answers a sentinel
;;    where it wants null. The corpus caught both. It is also the LIVE path
;;    for `minor.stringify` and `minor.pathify`: their corpus subjects are
;;    one-arity wrappers, so they take the nil and make struct's own no-arg
;;    call themselves.
;;
;;    Which arm a subject has is READ OFF THE FUNCTION (`accepts-no-args?`),
;;    never discovered by calling it and catching ArityException - see the
;;    note on that function.
;;
;; 2a. WHAT RAN IS COUNTED, not what the corpus declared. A section's pass
;;    count comes from `subject-calls`, incremented inside the subject
;;    wrapper - the one place only the engine can reach - and `runsetflags`
;;    returns the delta across the set. A count taken from the section's own
;;    `set` prints the same number whether the engine ran or was never
;;    called, which makes it evidence of nothing.
;;
;; 3. THE CTX CHANNEL (`live-map`). omni snapshots `entry.ctx` BEFORE calling
;;    the subject, then matches against that snapshot afterwards. In every
;;    mutable-language port the snapshot and the argument are the same live
;;    object, so a utility that writes `ctx.spec.headers.authorization` is
;;    visible to `match: {ctx: ...}` (9 primary entries turn on exactly that).
;;    Clojure's data is immutable, so the snapshot would freeze the
;;    pre-call state and every such assertion would read null. `contextify`
;;    therefore hands omni a LIVE VIEW: a type that satisfies `map?` (so
;;    `u/ismap`, `u/getpath`, `u/deepequal` and `u/stringify` all accept it)
;;    but reads through to the mutable map the subject actually mutates. The
;;    port's own `:runsetflags-args` channel carries the ARGUMENT writeback;
;;    this carries the ctx one, which `runsetflags-args` cannot reach.
;;
;; 4. LIVE OBJECTS CROSS BY REFERENCE. A value that belongs to neither model -
;;    the provider, an SDK client, a Context atom - passes through the
;;    converters as a leaf, so subjects keep real object identity (and so a
;;    cyclic SDK object is never walked).

(ns sdk.test.omni
  (:require [voxgig.omni.runner :as runner]
            [voxgig.omni.util :as u]
            [voxgig.struct :as vs]
            [sdk.core :as core]
            [sdk.client :as client]
            [clojure.string :as str])
  (:import [java.util LinkedHashMap ArrayList List Map IdentityHashMap]))


;; omni's sentinels and error predicate, re-exported so the corpus suites and
;; the smoke test never reach into the vendored namespaces themselves.
(def NULLMARK u/NULLMARK)
(def UNDEFMARK u/UNDEFMARK)
(def EXISTSMARK u/EXISTSMARK)
(def ABSENT u/ABSENT)

(defn omni-error? [err] (runner/omni-error? err))
(defn deep-equal? [a b] (u/deepequal a b))
(defn stringify [val] (u/stringify val))


;; --------------------------------------------------------------------------
;; Decision 4: the live-object marker.
;; --------------------------------------------------------------------------

(def ^:private LIVEMETA ::live)

(defn- mark-live [val] (vary-meta val assoc LIVEMETA true))

(defn- live? [val]
  (boolean (and (instance? clojure.lang.IObj val) (get (meta val) LIVEMETA))))


;; --------------------------------------------------------------------------
;; Decision 3: a live-reading omni map over a mutable struct map.
;; --------------------------------------------------------------------------

(defprotocol ILiveMap
  (live-backing [this] "The mutable struct map this view reads through to."))

(declare ->omni ->struct)

;; A `map?` that is not a map: every read re-converts the mutable backing map,
;; so omni sees the state as it is AT MATCH TIME rather than at call time.
;; `extra` carries keys omni assoc'd on afterwards (it attaches the active
;; client under "client"), which must not be written into the SDK's own node.
(defn- live-map [^Map backing extra]
  (let [snap (fn [] (merge (->omni backing) extra))]
    (reify
      ILiveMap
      (live-backing [_] backing)

      clojure.lang.ILookup
      (valAt [_ k] (get (snap) k))
      (valAt [_ k nf] (get (snap) k nf))

      clojure.lang.Associative
      (containsKey [_ k] (contains? (snap) k))
      (entryAt [_ k] (find (snap) k))
      (assoc [_ k v] (live-map backing (assoc extra k v)))

      clojure.lang.IPersistentMap
      (assocEx [_ k v] (live-map backing (assoc extra k v)))
      (without [_ k] (live-map backing (dissoc extra k)))

      clojure.lang.IPersistentCollection
      (count [_] (count (snap)))
      (cons [_ o] (conj (snap) o))
      (empty [_] (array-map))
      (equiv [_ o] (= (snap) o))

      clojure.lang.Seqable
      (seq [_] (seq (snap)))

      Iterable
      (iterator [_] (.iterator ^Iterable (snap))))))

(defn- live-map? [val] (instance? sdk.test.omni.ILiveMap val))


;; --------------------------------------------------------------------------
;; Decision 1: the converters.
;; --------------------------------------------------------------------------

(defn ->struct
  "omni's immutable model -> the SDK's mutable one.

   ABSENT becomes struct's own NOARG (decision 2). A live view is unwrapped to
   the very map it reads, so a subject handed a contextified ctx mutates the
   node omni will match against (decision 3). Anything that is neither an omni
   map nor an omni list crosses as a leaf (decision 4)."
  [val]
  (cond
    (u/isabsent val) vs/NOARG
    (nil? val) nil
    (live-map? val) (live-backing val)
    (live? val) val
    (map? val) (let [out (LinkedHashMap.)]
                 (doseq [[k v] val] (.put out (str k) (->struct v)))
                 out)
    (vector? val) (let [out (ArrayList.)]
                    (doseq [v val] (.add out (->struct v)))
                    out)
    :else val))


(defn ->omni
  "The SDK's mutable model -> omni's immutable one.

   Clojure's own maps and vectors are already omni values, but a clojure map
   is ALSO a java.util.Map and a clojure vector a java.util.List, so the
   persistent branches must be tested first. `seen` guards a cyclic mutable
   node: struct's nodes are trees, but an SDK object reachable from one is not
   necessarily, and a converter that hangs is worse than one that truncates."
  ([val] (->omni val (IdentityHashMap.)))
  ([val ^IdentityHashMap seen]
   (cond
     (identical? vs/NOARG val) u/ABSENT
     (nil? val) nil
     (live-map? val) val
     (live? val) val
     (map? val) (reduce (fn [out k] (assoc out (str k) (->omni (get val k) seen)))
                        (array-map)
                        (keys val))
     (vector? val) (mapv #(->omni % seen) val)

     (instance? Map val)
     (if (.containsKey seen val)
       (array-map)
       (do (.put seen val true)
           (let [out (reduce (fn [out k] (assoc out (str k) (->omni (.get ^Map val k) seen)))
                             (array-map)
                             (vec (.keySet ^Map val)))]
             (.remove seen val)
             out)))

     (instance? List val)
     (if (.containsKey seen val)
       []
       (do (.put seen val true)
           (let [out (mapv #(->omni % seen) (vec val))]
             (.remove seen val)
             out)))

     :else val)))


;; --------------------------------------------------------------------------
;; Loading the corpus.
;; --------------------------------------------------------------------------

;; THE CORPUS IS PARSED BY THE SDK'S OWN JSON READER, not omni's.
;;
;; omni's readers model every JSON number as a double - the clojure port's
;; `json/parse` calls Double/parseDouble unconditionally, and its java peer
;; documents `number -> Double`. On most ports that is invisible, because
;; their struct has one numeric type. Clojure's does not: `typify` answers
;; T_integer for a Long and T_decimal for a Double, and `validate` prints
;; "integer" or "decimal" from it. Read through omni's parser, every `1` in
;; the corpus arrives as 1.0 and fourteen struct sections fail on the word
;; "decimal" - not because the SDK is wrong, but because the spec was
;; re-typed on the way in.
;;
;; omni's own `make-runner` takes an ALREADY-PARSED spec, so the fix needs no
;; change to the vendored files (which are read-only anyway): parse with the
;; reader the SDK itself uses, then convert into omni's model. Longs survive
;; the round trip, and omni compares numbers by value (`==`, and `numstr`
;; renders 5.0 as 5), so nothing downstream notices.
;;
;; The one distinction this cannot restore is an authored `1.0`: JSON does not
;; carry it and neither reader can. The corpus has no such literal today.
;; Upstream follow-up: omni's clojure json.clj could parse an integral literal
;; with no '.'/'e' as a Long, as the SDK's own reader does.
(defn load-spec [path]
  (when-not (.exists (java.io.File. ^String path))
    (throw (ex-info (str "omni: cannot read spec: " path) {})))
  (->omni (core/json-parse (slurp path))))


;; --------------------------------------------------------------------------
;; The subject boundary.
;; --------------------------------------------------------------------------

;; Decision 2a: the execution counter. omni calls the wrapped subject exactly
;; once per entry, and nothing else calls it at all, so the delta across a set
;; is the number of entries the ENGINE ran. Every corpus count in this port is
;; read from here.
(def ^:private subject-calls (atom 0))

(defn subject-call-count
  "Subject invocations since this process started."
  []
  @subject-calls)


;; Decision 2: does `f` have a genuine zero-argument arm?
;;
;; Read off the function object, not discovered by calling it. A
;; `(catch ArityException ...)` around the zero-arity call cannot tell a
;; subject that has NO zero-arity arm from one whose zero-arity arm raised an
;; ArityException from its own body - and for the second, catching it retries
;; the subject with nil (after any side effect of the first, partial call has
;; already landed) and reports the retry as a pass. A real crash becomes a
;; green entry.
;;
;; A fixed arity is a declared `invoke` of no parameters on the function's OWN
;; class - declared, never inherited, because `clojure.lang.AFn` declares an
;; `invoke()` that exists only to raise ArityException. A variadic `fn` is a
;; RestFn: its fixed arms are declared the same way, and its variadic arm
;; accepts no arguments exactly when it requires none.
(defn- accepts-no-args? [f]
  (boolean
   (or (some (fn [^java.lang.reflect.Method m]
               (and (= "invoke" (.getName m))
                    (zero? (alength (.getParameterTypes m)))))
             (.getDeclaredMethods ^Class (class f)))
       (and (instance? clojure.lang.RestFn f)
            (zero? (.getRequiredArity ^clojure.lang.RestFn f))))))


;; omni calls a subject with ONE argument: the resolved argument VECTOR. The
;; SDK's subjects are ordinary functions of their arguments, so the vector is
;; applied - which is also what keeps arity honest for decision 2.
;;
;; The return is `[args result]`, omni's `:runsetflags-args` shape: clojure's
;; data is immutable, so handing the arguments back is the only way a
;; `match: {args: ...}` can see what a subject did with them.
(defn- wrap-subject [subject]
  (when (ifn? subject)
    (fn [args]
      ;; Counted BEFORE the call, so an entry whose subject throws - which is
      ;; a pass when the entry expects it - still counts as executed.
      (swap! subject-calls inc)
      (let [converted (mapv ->struct args)
            ;; Decision 2: a lone ABSENT is "no argument at all", so the call
            ;; carries no argument. A subject without that arity gets nil.
            noarg? (and (= 1 (count args)) (u/isabsent (first args)))
            result (if noarg?
                     (if (accepts-no-args? subject) (subject) (subject nil))
                     (apply subject converted))]
        [(mapv ->omni converted) (->omni result)]))))


;; `makeContext` -> `:make-context`: corpus subject names are camelCase, the
;; SDK utility is a kebab-case keyword map.
(defn- utility-key [name]
  (-> (str name)
      (str/replace #"([a-z0-9])([A-Z])" "$1-$2")
      (str/lower-case)
      (keyword)))


;; The live SDK as an omni provider. Marked live so the converters never walk
;; it: omni attaches it to every contextified ctx under "client".
(defn- sdk-provider [sdk]
  (let [utility (when sdk (core/get-utility sdk))]
    (mark-live
     {:sdk sdk
      :utility utility

      ;; The corpus suites hand most subjects in per-set; this is the by-name
      ;; fallback omni uses when they do not.
      :subject (fn [name]
                 (when utility
                   (wrap-subject (get (deref utility) (utility-key name)))))

      ;; A DEF.client entry becomes another test SDK, rewrapped the same way.
      :client (fn [options]
                (sdk-provider (client/test-sdk nil (->struct options))))

      ;; Decision 3: omni keeps this return value as BOTH args[0] and
      ;; entry.ctx, so making it a live view over one mutable map is what
      ;; makes `match: {ctx: ...}` see a utility's writes.
      :contextify (fn [val]
                    (if (u/ismap val)
                      (live-map (->struct val) (array-map))
                      val))

      ;; Client options may reference the runner store.
      :inject (fn [options store]
                (let [opts (->struct options)]
                  (vs/inject opts (->struct store))
                  (->omni opts)))})))


;; --------------------------------------------------------------------------
;; The runner.
;; --------------------------------------------------------------------------

(defn make-runner
  "Vendored omni's `make-runner`, in the shape the corpus suites use.

   `specref` is a path to the shared corpus, or an already-parsed spec in
   omni's own value model (which keeps the smoke test free of fixture files)."
  ([specref] (make-runner specref nil))
  ([specref sdk]
   (let [provider (if sdk (sdk-provider sdk) (mark-live {}))
         spec (if (string? specref) (load-spec specref) specref)
         omnirunner (runner/make-runner spec provider)]
     (fn make-runpack
       ([name] (make-runpack name nil))
       ([name store]
        (let [runpack (omnirunner name store)
              ;; Always the `-args` entry point: the plain one drops the
              ;; argument writeback, and clojure has no other channel for it.
              ;;
              ;; RETURNS THE NUMBER OF ENTRIES THE ENGINE RAN (decision 2a),
              ;; measured at the subject wrapper. The suites compare it with
              ;; the set they handed in, so an engine that never called the
              ;; subject reports 0 rather than the set's own size.
              runsetflags (fn [testspec flags testsubject]
                            (let [before @subject-calls]
                              ((:runsetflags-args runpack)
                               testspec flags (wrap-subject testsubject))
                              (- @subject-calls before)))]
          {:spec (:spec runpack)
           :runset (fn [testspec testsubject] (runsetflags testspec {} testsubject))
           :runsetflags runsetflags
           :subject (:subject runpack)
           :client provider
           :provider provider}))))))


(defn null-modifier
  "Convert NULLMARK sentinels back into real nulls.

   NOT a delegation to omni's `nullmodifier`, deliberately: omni's RETURNS the
   replacement, while struct's `inject` passes this as its `modify` hook and
   expects it to MUTATE `parent[key]` in place."
  [val key parent & _]
  (cond
    (= NULLMARK val) (vs/setprop parent key nil)
    (string? val) (vs/setprop parent key (str/replace val NULLMARK "null"))))
