;; VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (clojure/src/voxgig/sekreto/json.clj)
;; Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
;; Minimal JSON support for sekreto.
;;
;; sekreto adds no third-party dependencies, so it carries just enough JSON
;; to read a vault's answer and write the CLI's own line of output. It is
;; deliberately not a general-purpose library, and it is not
;; clojure.data.json.
;;
;; Values are plain Clojure data - maps with string keys, vectors, strings,
;; doubles, booleans and nil - with ONE addition. Clojure has nil for JSON
;; null, so "there is no value here" needs a marker of its own: NONE. A
;; store answering `null`, and a store answering text that is not JSON at
;; all, mean different things, and only the second is a store that could not
;; answer coherently. `parse` returns NONE for the second and nil for the
;; first, which is the distinction the callers of fetchjson need.
;;
;; A port of typescript/src/Json.ts, which is canonical.

(ns voxgig.sekreto.json
  (:require [clojure.string :as string]))

;; No value at all: text that is not JSON, or a walk that ran off the end of
;; an object. Never a value a store legitimately sent.
(def NONE ::none)

(defn none?
  "Is this the no-value marker, rather than a value (nil included)?"
  [value]
  (identical? NONE value))

(defn omap
  "An insertion-ordered map, built in one go from key/value pairs.

  `array-map` keeps insertion order, but only until it is grown past eight
  entries by `assoc` - after that it promotes to a hash map, whose iteration
  order is its own. Redaction order and a signed payload's field order both
  depend on the order a map was built in, so ordered maps here are built
  from their pairs rather than assoc'd up one at a time. A repeated key
  keeps its first position and takes its last value, the way an object
  literal does."
  [pairs]
  (loop [keys [] values {} rest (seq pairs)]
    (if (nil? rest)
      (apply array-map (mapcat (fn [key] [key (get values key)]) keys))
      (let [[key value] (first rest)]
        (recur (if (contains? values key) keys (conj keys key))
               (assoc values key value)
               (next rest))))))

(defn numstr
  "Render a number the way every other port does: a whole number has no
  fractional tail, so a JSON `1` read back and printed stays `1`."
  [value]
  (let [number (double value)]
    (cond
      (or (Double/isNaN number) (Double/isInfinite number)) "null"
      (and (== number (Math/rint number)) (> 9007199254740992.0 (Math/abs number)))
      (str (long number))
      :else (str number))))

(defn quotestr
  "Render a string as a JSON string literal, quotes included."
  [^String text]
  (let [out (StringBuilder. "\"")]
    (doseq [ch text]
      (cond
        (= \" ch) (.append out "\\\"")
        (= \\ ch) (.append out "\\\\")
        (= \newline ch) (.append out "\\n")
        (= \return ch) (.append out "\\r")
        (= \tab ch) (.append out "\\t")
        (> 0x20 (int ch)) (.append out (format "\\u%04x" (int ch)))
        :else (.append out ch)))
    (.toString (.append out \"))))

(defn stringify
  "Render a value as compact JSON, keys in the order the map holds them."
  [value]
  (cond
    (none? value) "null"
    (nil? value) "null"
    (boolean? value) (if value "true" "false")
    (string? value) (quotestr value)
    (number? value) (numstr value)
    (vector? value) (str "[" (string/join "," (map stringify value)) "]")
    (map? value) (str "{"
                      (string/join
                       ","
                       (map (fn [[key entry]] (str (quotestr (str key)) ":" (stringify entry)))
                            value))
                      "}")
    :else (quotestr (str value))))

;; ------------------------------------------------------------- the reader
;;
;; Each step takes the text and a position and answers [value position].
;; Malformed input throws, and `parse` - the only entry point - turns that
;; into NONE, so a caller never sees this exception.

(defn- bad [message]
  (throw (ex-info (str "sekreto: json: " message) {:json true})))

(defn- ws? [ch]
  (or (= \space ch) (= \tab ch) (= \newline ch) (= \return ch)))

(defn- skipws [^String text pos]
  (loop [at pos]
    (if (and (> (.length text) at) (ws? (.charAt text at))) (recur (inc at)) at)))

(declare readvalue)

(defn- readword [^String text pos ^String word value]
  (if (and (>= (.length text) (+ pos (count word)))
           (= word (subs text pos (+ pos (count word)))))
    [value (+ pos (count word))]
    (bad (str "bad literal at " pos))))

(defn- readstr [^String text pos]
  (when (or (<= (.length text) pos) (not= \" (.charAt text pos)))
    (bad (str "expected string at " pos)))

  (loop [at (inc pos)
         out (StringBuilder.)]
    (when (<= (.length text) at)
      (bad "unterminated string"))

    (let [ch (.charAt text at)]
      (cond
        (= \" ch) [(.toString out) (inc at)]

        (not= \\ ch) (recur (inc at) (.append out ch))

        (<= (.length text) (inc at)) (bad "unterminated string")

        :else
        (let [escape (.charAt text (inc at))]
          (case escape
            \" (recur (+ at 2) (.append out \"))
            \\ (recur (+ at 2) (.append out \\))
            \/ (recur (+ at 2) (.append out \/))
            \b (recur (+ at 2) (.append out \backspace))
            \f (recur (+ at 2) (.append out \formfeed))
            \n (recur (+ at 2) (.append out \newline))
            \r (recur (+ at 2) (.append out \return))
            \t (recur (+ at 2) (.append out \tab))
            \u (if (< (.length text) (+ at 6))
                 (bad "bad unicode escape")
                 (recur (+ at 6)
                        (.append out (char (Integer/parseInt (subs text (+ at 2) (+ at 6)) 16)))))
            (bad (str "bad escape [" escape "] at " at))))))))

(defn- numchar? [ch]
  (or (Character/isDigit ^char ch)
      (= \. ch) (= \e ch) (= \E ch) (= \- ch) (= \+ ch)))

(defn- readnum [^String text pos]
  (let [end (loop [at pos]
              (if (and (> (.length text) at) (numchar? (.charAt text at))) (recur (inc at)) at))
        span (subs text pos end)]
    (try
      [(Double/parseDouble span) end]
      (catch NumberFormatException _ (bad (str "bad number [" span "] at " pos))))))

(defn- readarr [^String text pos]
  (let [after (skipws text (inc pos))]
    (if (and (> (.length text) after) (= \] (.charAt text after)))
      [[] (inc after)]
      (loop [at after
             out []]
        (let [[value next] (readvalue text (skipws text at))
              done (skipws text next)]
          (when (<= (.length text) done)
            (bad "unterminated array"))
          (case (.charAt text done)
            \, (recur (inc done) (conj out value))
            \] [(conj out value) (inc done)]
            (bad (str "expected ',' or ']' at " done))))))))

(defn- readobj [^String text pos]
  (let [after (skipws text (inc pos))]
    (if (and (> (.length text) after) (= \} (.charAt text after)))
      [(omap []) (inc after)]
      (loop [at after
             pairs []]
        (let [[key next] (readstr text (skipws text at))
              colon (skipws text next)]
          (when (or (<= (.length text) colon) (not= \: (.charAt text colon)))
            (bad (str "expected ':' at " colon)))

          (let [[value after-value] (readvalue text (skipws text (inc colon)))
                done (skipws text after-value)]
            (when (<= (.length text) done)
              (bad "unterminated object"))
            (case (.charAt text done)
              \, (recur (inc done) (conj pairs [key value]))
              \} [(omap (conj pairs [key value])) (inc done)]
              (bad (str "expected ',' or '}' at " done)))))))))

(defn- readvalue [^String text pos]
  (when (<= (.length text) pos)
    (bad "unexpected end"))

  (case (.charAt text pos)
    \{ (readobj text pos)
    \[ (readarr text pos)
    \" (readstr text pos)
    \t (readword text pos "true" true)
    \f (readword text pos "false" false)
    \n (readword text pos "null" nil)
    (readnum text pos)))

(defn parse
  "Parse JSON text. NONE for anything unreadable - which the caller must
  tell apart from a literal `null` body, since only the first means the
  store could not answer coherently."
  [text]
  (if (or (nil? text) (= "" text))
    NONE
    (try
      (let [[value pos] (readvalue text (skipws text 0))]
        (if (> (count text) (skipws text pos)) NONE value))
      (catch Exception _ NONE))))

;; ------------------------------------------------------------- the reads
;;
;; Every read answers nil (or NONE, for `dig`) rather than throwing, so a
;; provider can walk a response body it did not write without checking each
;; step. NONE in, NONE out.

(defn dig
  "Walk nested objects; NONE the moment a step is not there."
  [value & keys]
  (reduce (fn [at key]
            (if (and (map? at) (contains? at key))
              (get at key)
              (reduced NONE)))
          value
          keys))

(defn astext
  "This value as the text a caller would print, or nil when there is no
  value at all. A JSON null is \"no value\": every provider here treats it
  as a miss rather than as the string \"null\"."
  [value]
  (cond
    (none? value) nil
    (nil? value) nil
    (string? value) value
    (boolean? value) (if value "true" "false")
    (number? value) (numstr value)
    :else (stringify value)))

(defn asstr [value] (when (string? value) value))

(defn asnum [value] (when (and (number? value) (not (boolean? value))) value))

(defn asarr [value] (when (vector? value) value))

(defn asobj [value] (when (map? value) value))
