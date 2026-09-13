;; VENDORED: @voxgig/plugin sdk-20260908-1556-0 (clojure/src/voxgig/plugin/version.clj)
;; Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
(ns voxgig.plugin.version
  "Versions and ranges (section 11.2).

  TWO FIELDS AND ONE PREDICATE. A capability declares `version`, a
  concrete version. A requirement declares `range`. A requirement is
  satisfied when the names match, the `match` passes, and the provider's
  `version` falls inside the requirement's `range`.

  That is the whole rule. There is no third field and no second comparison
  - an earlier draft added a provider-side `compat` range, which left
  three values and no statement of how they combine, and three defensible
  readings of one declaration is worse than the ambiguity it was
  introduced to fix."
  (:require [voxgig.plugin.types :as t]))

(def ^:private version-re #"\A(\d+)(?:\.(\d+))?(?:\.(\d+))?\z")

(def component-max
  "A COMPONENT IS BOUNDED, and the bound is the model's, not the host
  language's. Clojure promotes past a long and javascript stops being
  exact past 2**53, so `9223372036854775808.0.0` parsed to an exact value
  here and a rounded one there. 2**31-1 is the smallest bound every target
  language holds exactly, which makes it the model's."
  2147483647)

(defn- component [digits whole field]
  (let [value (bigint digits)]
    (when (< component-max value)
      (t/fail "plugin_bad_range"
              (str "version component out of range in " whole ": " digits)
              {field whole}))
    (long value)))

(defn parse-range
  "Two forms and no more (section 11.2):

    '2.1'    >= 2.1.0 and < 3.0.0
    '~2.1'   >= 2.1.0 and < 2.2.0"
  [range]
  (when-not (and (string? range) (seq range))
    (t/fail "plugin_bad_range" (str "invalid range: " range) {"range" range}))
  (let [tilde (.startsWith ^String range "~")
        body (if tilde (subs range 1) range)
        m (re-matches version-re body)]
    (when (nil? m)
      (t/fail "plugin_bad_range" (str "invalid range: " range) {"range" range}))
    (let [major (component (m 1) range "range")
          minor (if (nil? (m 2)) 0 (component (m 2) range "range"))
          patch (if (nil? (m 3)) 0 (component (m 3) range "range"))]
      {"lo" [major minor patch]
       "hi" (if tilde [major (inc minor) 0] [(inc major) 0 0])})))

(defn parse-version [version]
  (when-not (string? version)
    (t/fail "plugin_bad_range" (str "invalid version: " version) {"version" version}))
  (let [m (re-matches version-re version)]
    (when (nil? m)
      (t/fail "plugin_bad_range" (str "invalid version: " version) {"version" version}))
    [(component (m 1) version "version")
     (if (nil? (m 2)) 0 (component (m 2) version "version"))
     (if (nil? (m 3)) 0 (component (m 3) version "version"))]))

(defn version-cmp [a b]
  (or (first (for [i (range 3)
                   :let [x (or (get a i) 0) y (or (get b i) 0)]
                   :when (not= x y)]
               (if (< x y) -1 1)))
      0))

(defn satisfies-range?
  "The one satisfaction predicate: lo <= version < hi."
  [version range]
  (let [v (parse-version version)
        r (parse-range range)]
    (and (>= (version-cmp v (r "lo")) 0) (neg? (version-cmp v (r "hi"))))))

(defn satisfies-q?
  "`satisfies-range?` for the internal callers that treat an unparseable
  version or range as \"does not satisfy\" - Capability and Graph, both of
  which run over data the corpus has already admitted."
  [version range]
  (try (satisfies-range? version range) (catch clojure.lang.ExceptionInfo _ false)))

(defn version-parts
  "The numeric parts of a version, or zeros - a SORT KEY, never a check."
  [text]
  (try (parse-version text) (catch clojure.lang.ExceptionInfo _ [0 0 0])))
