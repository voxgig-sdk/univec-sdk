;; VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (clojure/src/voxgig/sekreto/core.clj)
;; Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
;; The names, the errors and the text helpers - the half of sekreto that
;; does not know what a provider is.
;;
;; `voxgig.sekreto.providers` builds the four built-in kinds out of these,
;; and `voxgig.sekreto.chain` builds a chain out of those; `voxgig.sekreto`
;; is the one namespace a consumer requires, and republishes all three.
;;
;; The split is not a matter of taste. The provider kinds need the name
;; helpers, so the namespace that defines those cannot be the one that
;; builds a chain out of kinds - a namespace cycle is a load error in
;; Clojure, not a warning.
;;
;; A port of typescript/src/Sekreto.ts, which is canonical.

(ns voxgig.sekreto.core
  (:require [clojure.string :as string]
            [voxgig.sekreto.json :as json])
  (:import [java.util Locale]))

(defn sekretoerror
  "Anything sekreto refuses to do: a bad name, a missing secret, a provider
  that could not be reached. One error type, carrying the message the spec
  pins, so a caller can tell the library's own refusals from a bug."
  [message]
  (ex-info message {:sekreto true}))

(defn sekretoerror?
  "Is this one of sekreto's own errors?"
  [err]
  (boolean (:sekreto (ex-data err))))

;; `re-matches` anchors at both ends of the whole input. The obvious `^...$`
;; with a find would not: in java.util.regex `$` also matches BEFORE a final
;; newline, so `token\n` would pass - and the spec has that exact case.
(def ^:private NAMEPART #"[a-z0-9_]+")

(defn dropsuffix
  "Drop a suffix if it is there. `.` and `_` both appear in names, so this
  is spelled out rather than reached for through a regex."
  [^String text ^String suffix]
  (if (.endsWith text suffix) (subs text 0 (- (count text) (count suffix))) text))

(defn- upper
  "Upper case in the root locale. The default locale is the machine's, and
  in a Turkish one `i` upper-cases to a dotted capital that is not ASCII -
  so an environment variable's name would depend on where the process runs."
  [^String text]
  (.toUpperCase text Locale/ROOT))

(defn segments
  "Split on the literal dot, KEEPING trailing empties: the usual split drops
  them, which would make `a.` a valid one-segment name."
  [^String name]
  (string/split name #"\." -1))

(defn validname
  "Is this a well-formed secret name: dot-separated lowercase segments?"
  [name]
  (and (string? name)
       (not= "" name)
       (every? (fn [part] (some? (re-matches NAMEPART part))) (segments name))))

(defn checkname
  "The name, or a sekreto error. Every entry point checks its name here."
  [name]
  (when-not (validname name)
    (throw (sekretoerror (str "sekreto: invalid name: " (if (nil? name) "" name)))))
  name)

(defn envkey
  "The environment-variable key for a name: `api.token` -> `API_TOKEN`."
  ([name] (envkey name nil))
  ([name prefix]
   (str (or prefix "") (upper (string/join "_" (segments (checkname name)))))))

(defn vaultref
  "Where a name lives in a KV vault: `api.token` -> `api` / `token`.

  A single-segment name has no path of its own, so it becomes a secret of
  that name with the conventional field `value`."
  [name]
  (let [parts (segments (checkname name))]
    (if (= 1 (count parts))
      {:path (nth parts 0) :field "value"}
      {:path (string/join "/" (butlast parts)) :field (last parts)})))

(defn flatname
  "A name flattened to one segment: `api.token` -> `api_token` (GCP Secret
  Manager, `_`) or `api-token` (Azure Key Vault, `-`).

  Those stores have no path hierarchy and reject dots in ids, so the dots
  become the store's conventional separator. With `-` as the separator,
  underscores flatten too: Azure Key Vault's alphabet is letters, digits
  and hyphens only, and a valid sekreto name like `with_underscore` must
  still be representable there. (The resulting `.`/`_` collision mirrors
  the documented envkey behaviour, where both already map to `_`.)"
  [name sep]
  (let [flat (string/join sep (segments (checkname name)))]
    (if (= "-" sep) (string/replace flat "_" "-") flat)))

(defn awsparam
  "The AWS SSM Parameter Store name for a name: dots become the path
  hierarchy, rooted at `/` (or at a prefix): `db.pass.main` ->
  `/db/pass/main`, or `/app/db/pass/main` under prefix `/app`."
  ([name] (awsparam name nil))
  ([name prefix]
   (let [checked (checkname name)
         base (or prefix "")
         base (if (and (not= "" base) (not (string/starts-with? base "/"))) (str "/" base) base)
         base (dropsuffix base "/")]
     (str base "/" (string/join "/" (segments checked))))))

(defn- unescape [^String text]
  (let [out (StringBuilder.)]
    (loop [index 0]
      (if (<= (count text) index)
        (.toString out)
        (let [ch (.charAt text index)]
          (if (and (= \\ ch) (> (count text) (inc index)))
            (let [next (.charAt text (inc index))]
              (case next
                \n (.append out \newline)
                \r (.append out \return)
                \t (.append out \tab)
                \\ (.append out \\)
                \" (.append out \")
                (.append (.append out \\) next))
              (recur (+ index 2)))
            (do (.append out ch)
                (recur (inc index)))))))))

(defn- quoted? [^String value ^String mark]
  (and (<= 2 (count value)) (string/starts-with? value mark) (string/ends-with? value mark)))

(defn parsedotenv
  "Parse `.env` text into a map of raw keys to values, in the file's order.

  Deliberately small: `KEY=value`, optional `export`, `#` comments on their
  own line, and single- or double-quoted values (double quotes also
  unescape `\\n`, `\\r`, `\\t` and `\\\\`). A line with no `=` is skipped."
  [text]
  (if-not (string? text)
    (json/omap [])
    (json/omap
     (for [rawline (string/split text #"\n" -1)
           :let [line (string/trim (dropsuffix rawline "\r"))]
           :when (and (not= "" line) (not (string/starts-with? line "#")))
           :let [entry (if (string/starts-with? line "export ")
                         (string/trim (subs line 7))
                         line)
                 eq (string/index-of entry "=")]
           :when (and (some? eq) (< 0 eq))
           :let [key (string/trim (subs entry 0 eq))
                 value (string/trim (subs entry (inc eq)))]]
       [key (cond
              (quoted? value "\"") (unescape (subs value 1 (dec (count value))))
              (quoted? value "'") (subs value 1 (dec (count value)))
              :else value)]))))

(defn redact
  "Replace known secret values in text with `[redacted]`.

  Only values of four characters or more are replaced: shorter ones are too
  likely to appear in ordinary text, and redacting them would make logs
  unreadable without making them safer."
  [text values]
  (let [body (if (string? text) text "")
        ;; Longest first, so a value that contains a shorter one is redacted
        ;; whole rather than left with a `[redacted]` in its middle. `sort-by`
        ;; is stable, so equal lengths keep the caller's order - and the
        ;; caller's own list is never reordered.
        usable (->> (or values [])
                    (filter string?)
                    (filter (fn [value] (<= 4 (count value))))
                    (sort-by (fn [value] (- (count value)))))]
    (reduce (fn [out value] (string/replace out value "[redacted]")) body usable)))

(defn notempty
  "The string, when it is one and is not empty; nil otherwise. Config that
  arrives as an empty string means \"not set\" everywhere in this library."
  [value]
  (when (and (string? value) (not= "" value)) value))

(defn getenv
  "An environment variable, or nil. NOT emptied: a variable set to the empty
  string is a value the env provider answers with, and only the callers that
  treat empty as unset - `firstof` in the shared HTTP helpers - say so."
  [name]
  (System/getenv name))
