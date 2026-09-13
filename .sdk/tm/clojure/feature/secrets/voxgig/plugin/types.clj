;; VENDORED: @voxgig/plugin sdk-20260908-1556-0 (clojure/src/voxgig/plugin/types.clj)
;; Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
(ns voxgig.plugin.types
  "The value model, the error type, and the JSON writer.

  CLOJURE IS THE PORT WHERE THE VALUE MODEL COSTS NOTHING. Maps are not
  vectors, `nil` is a value a map can hold, `contains?` separates an
  authored null from an absent key, and `(= true 1)` is false. Every trap
  php, perl, lua and java document is absent here, so what is left is the
  two things clojure does make you decide.

  KEYS ARE STRINGS, NOT KEYWORDS. Idiomatic clojure would read
  `(:status entry)`, and every corpus value would then need converting on
  the way in and back on the way out - two conversions whose only job is
  to make a foreign document look native, and which lose the distinction
  between the key \"a\" and the keyword :a in a document that used both.
  The corpus is JSON; this port holds JSON.

  ORDER IS NEVER THE MAP'S. A clojure map past eight entries is a hash-map
  and `keys` on one is unordered, so every walk of a map goes through
  `sorted-keys`. That is not tidiness: without it a teardown order changes
  between two runs of the same process."
  (:refer-clojure :exclude [get]))

(def statuses
  "Section 5.1's seven statuses, and no more."
  ["declared" "loaded" "pending" "live" "failed" "loading" "closing"])

(def detail-order
  "Section 12's detail keys, in the order a message renders them. FIXED,
  not the map's: a message is a searchable log line, and a line whose
  fields move between runs is not."
  ["ref" "point" "name" "key" "spec" "refs" "kind" "directive" "cycle"
   "holders" "cause"])

(defn get
  "The value at a key, or nil. Absence and null read the same here."
  [m k]
  (when (map? m) (clojure.core/get m k)))

(defn has?
  "PRESENCE, which is what distinguishes an authored null from absence."
  [m k]
  (and (map? m) (contains? m k) true))

(defn sorted-keys
  "The keys of a map, SORTED - every walk of a map goes through here."
  [m]
  (if (map? m) (sort (keys m)) []))

(defn truthy
  "JSON truthiness, which clojure already agrees with: nil and false are
  its only falsey values, so 0 and \"\" count. It exists so the ports read
  alike at the sites that need it, and so a reader does not have to check
  whether the zero case was considered."
  [v]
  (not (or (nil? v) (false? v))))

(defn asint
  "An INTEGER, and only when the value is one. Section 7's band is an
  integer the document wrote as one; `true` and `\"2\"` are not bands, and
  clojure's `integer?` excludes both."
  [v]
  (cond
    (integer? v) (long v)
    (and (number? v) (== v (Math/floor (double v)))) (long v)
    :else nil))

(defn stable-sort-by
  "A STABLE sort by a key function.

  `sort-by` IS stable - it is `java.util.Arrays/sort` over an object array,
  documented stable. Stability is load-bearing: section 7's comparators
  fall through to a `pos` or ref tie-break that javascript's stable sort
  resolves BY POSITION, and a port that shuffled equal keys would order a
  teardown differently between two runs of one process. The name is kept
  so that one place in the port says so."
  [keyfn coll]
  (sort-by keyfn coll))

(defn same
  "JSON equality: same type, then same value.

  Clojure's `=` is type-strict across booleans, numbers and strings -
  `(= true 1)` and `(= \"1\" 1)` are both false - and it is STRICTER than
  javascript on numbers: `(= 1 1.0)` is false. `==` is the numeric
  comparison, so the two spellings of one number agree, which is what
  every other port does."
  [a b]
  (cond
    (and (number? a) (number? b)) (== a b)
    (and (map? a) (map? b))
    (and (= (count a) (count b))
         (every? (fn [[k v]] (and (contains? b k) (same v (clojure.core/get b k)))) a))
    (and (sequential? a) (sequential? b))
    (and (= (count a) (count b)) (every? identity (map same a b)))
    (or (sequential? a) (sequential? b) (map? a) (map? b)) false
    :else (= a b)))

;; --- JSON out ------------------------------------------------------
;;
;; The writer only. The parser is in `voxgig.plugin.json`, and neither is
;; `clojure.data.json`: section 16 permits ONE runtime dependency and
;; clojure has no port of it, so a `deps.edn` with a `:deps` map would be
;; a dependency every embedding host inherits for a hundred and fifty
;; lines of parser.

(defn- escape [^String s]
  (let [b (StringBuilder.)]
    (doseq [c s]
      (case c
        \" (.append b "\\\"")
        \\ (.append b "\\\\")
        \newline (.append b "\\n")
        \return (.append b "\\r")
        \tab (.append b "\\t")
        (if (< (int c) 0x20)
          (.append b (format "\\u%04x" (int c)))
          (.append b c))))
    (str b)))

(defn encode
  "COMPACT JSON. A number that is a whole double renders without its
  fraction, so `1.0` and `1` spell the same - the corpus writes both and a
  message quoting one must not depend on which."
  [v]
  (cond
    (nil? v) "null"
    (true? v) "true"
    (false? v) "false"
    (string? v) (str "\"" (escape v) "\"")
    (integer? v) (str v)
    (number? v) (let [d (double v)]
                  (if (== d (Math/floor d)) (str (long d)) (str d)))
    (map? v) (str "{" (clojure.string/join
                       ","
                       (map #(str "\"" (escape (str %)) "\":" (encode (clojure.core/get v %)))
                            (sorted-keys v)))
                  "}")
    (sequential? v) (str "[" (clojure.string/join "," (map encode v)) "]")
    :else "\"(opaque)\""))

;; --- errors --------------------------------------------------------

(defn format-error
  "`plugin/<code>: <text> [<key>=<value> ...]`

  Values render as COMPACT JSON, so a value containing a space or a
  bracket cannot break the parse, and a list renders as a JSON array. The
  bracket is absent entirely when no field applies."
  [code text details]
  (let [parts (for [k detail-order :when (has? details k)]
                (str k "=" (encode (get details k))))]
    (str "plugin/" code ": " text
         (if (empty? parts) "" (str " [" (clojure.string/join " " parts) "]")))))

(defn fail
  "Throw a section 12 error. One spelling, so every raise site reads the
  same. `ex-info` carries the code as DATA, which is what lets the corpus
  runner compare by code without parsing a message."
  ([code text] (fail code text {}))
  ([code text details]
   (throw (ex-info (format-error code text details)
                   {:plugin true :code code :text text :details details}))))

(defn code-of
  "The section 12 code of an error, or \"\" for one this library did not
  throw. The corpus compares by code, so the driver needs one place that
  knows how to read it."
  [e]
  (or (when (instance? clojure.lang.ExceptionInfo e)
        (:code (ex-data e)))
      ""))

(defn message-of [e]
  (if (instance? Throwable e) (or (.getMessage ^Throwable e) (str e)) (str e)))
