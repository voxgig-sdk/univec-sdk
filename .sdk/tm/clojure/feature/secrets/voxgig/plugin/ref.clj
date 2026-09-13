;; VENDORED: @voxgig/plugin sdk-20260908-1556-0 (clojure/src/voxgig/plugin/ref.clj)
;; Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
(ns voxgig.plugin.ref
  "Identity: name+tag, written `name$tag` (section 4).

  The four pure functions, and the whole of what `ref` pins. They are the
  first thing a new port implements and the first corpus section it
  passes."
  (:require [voxgig.plugin.types :as t]))

(def ^:private name-re
  "Section 4: `^[a-zA-Z@][a-zA-Z0-9.~_\\-/]*$`, max 1024.

  `\\A` and `\\z`, NOT `^` and `$`. Java's `$` matches at the end of input
  AND just before a final line terminator, so `^...$` would admit
  \"stripe\\n\" - a ref grammar with a newline in it, admitted by exactly
  the ports whose regex idiom differs from javascript's."
  #"\A[a-zA-Z@][a-zA-Z0-9.~_\-/]*\z")

(def ^:private tag-re
  "Section 4: `^[a-zA-Z0-9.~_-]+$`, max 1024, or empty.

  The asymmetry with a name is deliberate: a tag MAY start with a digit
  because auto-tagging assigns integer tags (`stripe$1`), and a tag admits
  neither `@` nor `/` because a name is a package specifier and a tag is
  not."
  #"\A[a-zA-Z0-9.~_-]+\z")

(def ^:private ref-max 1024)

(defn check-name [nm]
  (boolean (and (string? nm)
                (seq nm)
                (>= ref-max (count nm))
                (re-matches name-re nm))))

(defn check-tag [tag]
  (boolean (and (string? tag)
                ;; The empty tag is an ordinary tag (section 4 rule 2). The
                ;; single-instance case writes no tag and never learns tags
                ;; exist.
                (or (empty? tag)
                    (and (>= ref-max (count tag)) (re-matches tag-re tag))))))

(defn parse-ref
  "`name$tag` -> the pair. Canonicalizing: `stripe$` and `stripe` both give
  tag \"\"."
  [s]
  (when-not (string? s) (t/fail "plugin_bad_name" "ref must be a string"))
  ;; Split on the FIRST `$`. Nothing in the grammar decides this - `$` is
  ;; in neither character class - so the corpus is the arbiter (section 4
  ;; rule 5), and it picks the split that blames the part actually at
  ;; fault: `a$b$c` is a good name with a bad tag, not the reverse.
  (let [cut (.indexOf ^String s "$")
        nm (if (neg? cut) s (subs s 0 cut))
        tag (if (neg? cut) "" (subs s (inc cut)))]
    (when-not (check-name nm)
      (t/fail "plugin_bad_name" (str "invalid plugin name: " nm) {"name" nm}))
    (when-not (check-tag tag)
      (t/fail "plugin_bad_tag" (str "invalid plugin tag: " tag) {"name" nm "tag" tag}))
    {"name" nm "tag" tag}))

(defn format-ref
  "The pair -> `name$tag`. An empty tag NEVER writes the separator, which
  is the half of canonicalization `format-ref` owns: parse tolerates
  `stripe$`, format never produces it, so a round trip is idempotent."
  ([nm] (format-ref nm nil))
  ([nm tag]
   (let [tag (or tag "")]
     (when-not (check-name nm)
       (t/fail "plugin_bad_name" (str "invalid plugin name: " nm) {"name" nm}))
     (when-not (check-tag tag)
       (t/fail "plugin_bad_tag" (str "invalid plugin tag: " tag) {"name" nm "tag" tag}))
     (if (empty? tag) nm (str nm "$" tag)))))

(defn canon-ref
  "The canonical spelling of a ref. Section 4 rule 5: ports must
  canonicalize before comparison."
  [s]
  (let [r (parse-ref s)]
    (format-ref (r "name") (r "tag"))))

(defn canon
  "`canon-ref` for the internal callers that want the input back unchanged
  when it is not well formed. NEVER use it where a bad ref must be
  reported - the corpus pins plugin_bad_name at every public entry."
  [s]
  (try (canon-ref s) (catch clojure.lang.ExceptionInfo _ s)))

(defn ref-name [s]
  (try ((parse-ref s) "name") (catch clojure.lang.ExceptionInfo _ s)))
