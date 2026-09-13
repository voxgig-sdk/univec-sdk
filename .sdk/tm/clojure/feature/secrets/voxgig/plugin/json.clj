;; VENDORED: @voxgig/plugin sdk-20260908-1556-0 (clojure/src/voxgig/plugin/json.clj)
;; Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
(ns voxgig.plugin.json
  "The JSON parser, and the only one this port has.

  NO clojure.data.json AND NO cheshire (section 16). The library is
  allowed exactly one runtime dependency, `voxgig/struct`, which has no
  clojure port; everything else is what ships with clojure itself.
  Parsing the corpus is a hundred and fifty lines, and a hundred and fifty
  lines is cheaper than a `deps.edn` `:deps` map every embedding host
  inherits.

  Numbers parse as LONG when they are written as integers and DOUBLE
  otherwise, so `(integer? v)` answers section 7's band question without
  a second thought."
  (:require [voxgig.plugin.types :as t]))

(defn- ws? [c] (contains? #{\space \tab \newline \return} c))

(defn- skip [^String s at]
  (loop [at at]
    (if (and (< at (count s)) (ws? (.charAt s at))) (recur (inc at)) at)))

(declare parse-value)

(defn- parse-string [^String s at]
  ;; at points at the opening quote.
  (loop [at (inc at) b (StringBuilder.)]
    (when (<= (count s) at) (throw (ex-info "unterminated string" {})))
    (let [c (.charAt s at)]
      (cond
        (= \" c) [(str b) (inc at)]
        (= \\ c)
        (let [e (.charAt s (inc at))]
          (case e
            \u (do (.append b (char (Integer/parseInt (subs s (+ at 2) (+ at 6)) 16)))
                   (recur (+ at 6) b))
            (do (.append b (case e \n \newline \t \tab \r \return \b \backspace
                                   \f \formfeed e))
                (recur (+ at 2) b))))
        :else (do (.append b c) (recur (inc at) b))))))

(defn- parse-number [^String s at]
  (let [end (loop [i at]
              (if (and (< i (count s))
                       (or (Character/isDigit (.charAt s i))
                           (contains? #{\- \+ \. \e \E} (.charAt s i))))
                (recur (inc i))
                i))
        body (subs s at end)]
    (when (empty? body) (throw (ex-info (str "unexpected input at " at) {})))
    [(if (re-find #"[.eE]" body) (Double/parseDouble body) (Long/parseLong body)) end]))

(defn- parse-seq
  "Both containers, since the only differences are the closing character
  and what each element contributes."
  [^String s at ^Character close step init]
  (loop [at (skip s (inc at)) acc init]
    (if (= close (.charAt s at))
      [acc (inc at)]
      (let [[acc at] (step s at acc)
            at (skip s at)]
        (case (.charAt s at)
          \, (recur (skip s (inc at)) acc)
          (do (when (not= close (.charAt s at))
                (throw (ex-info (str "expected " close " at " at) {})))
              [acc (inc at)]))))))

(defn- parse-entry [^String s at acc]
  (let [[k at] (parse-string s (skip s at))
        at (skip s at)]
    (when (not= \: (.charAt s at)) (throw (ex-info (str "expected : at " at) {})))
    (let [[v at] (parse-value s (skip s (inc at)))]
      [(assoc acc k v) at])))

(defn- parse-element [^String s at acc]
  (let [[v at] (parse-value s (skip s at))]
    [(conj acc v) at]))

(defn- parse-value [^String s at]
  (let [c (.charAt s at)]
    (cond
      (= \{ c) (parse-seq s at \} parse-entry {})
      (= \[ c) (parse-seq s at \] parse-element [])
      (= \" c) (parse-string s at)
      (.startsWith (subs s at) "true") [true (+ at 4)]
      (.startsWith (subs s at) "false") [false (+ at 5)]
      (.startsWith (subs s at) "null") [nil (+ at 4)]
      :else (parse-number s at))))

(defn parse
  "Parse a JSON document. Throws on malformed input."
  [^String text]
  (let [[v at] (parse-value text (skip text 0))
        at (skip text at)]
    (when (not= at (count text))
      (throw (ex-info (str "trailing input at " at) {})))
    v))

(defn parse-scalar
  "Parse, FALLING BACK TO THE STRING ITSELF - so `8080` is a number, `true`
  is a boolean, `{\"a\":1}` is a map, and `hello` is the string it looks
  like rather than a parse error. Section 9.5's environment values."
  [text]
  (try (parse text) (catch Exception _ text)))
