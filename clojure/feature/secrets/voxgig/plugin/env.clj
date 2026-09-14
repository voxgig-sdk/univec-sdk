;; VENDORED: @voxgig/plugin sdk-20260908-1556-0 (clojure/src/voxgig/plugin/env.clj)
;; Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
(ns voxgig.plugin.env
  "Environment overrides (section 9.5) - level 7 of the ladder.

  One prefix, so nothing drifts: `VOXGIG_PLUGIN_*`.

    VOXGIG_PLUGIN_PROFILE            the profile name
    VOXGIG_PLUGIN_<REF>_<PATH>       one option
    VOXGIG_PLUGIN_ACTIVE/INACTIVE    comma-separated refs, INACTIVE wins

  THE ENCODING IS LOSSY, AND THIS SAYS SO RATHER THAN PRETENDING
  OTHERWISE. Ref and path are upper-snake with `$` -> `__` and `.` -> `_`.
  But `_` is legal in a name and in a tag, and the mapping folds case, so
  `retry$fast` and `retry__fast` both encode to `RETRY__FAST`.

  Rather than restrict a grammar the rest of the stack already uses, the
  host DETECTS THE COLLISION: it encodes every ref it holds, and a key two
  refs claim is `plugin_env_ambiguous`, naming both."
  (:require [voxgig.plugin.types :as t]
            [voxgig.plugin.ref :as r]
            [voxgig.plugin.json :as json]
            [clojure.string :as str]))

(def ^:private prefix "VOXGIG_PLUGIN_")

(defn encode-ref
  "`retry$fast` -> `RETRY__FAST`."
  [ref]
  (-> ref (str/replace "$" "__") (str/replace "." "_") str/upper-case))

(defn- check-reserved [ref reserved]
  (when (some #(= % (r/ref-name ref)) reserved)
    (t/fail "plugin_ref_reserved" (str "ref is reserved by the host: " ref) {"ref" ref})))

(defn- env-split [value]
  (->> (str/split (str value) #",") (map str/trim) (remove empty?) vec))

(defn- collisions
  "Encode every ref the host holds, and refuse a key that two of them
  claim. Done up front so the collision is reported even when no
  environment variable exercises it - a latent ambiguity is still an
  ambiguity, and finding it at deploy time is the failure this exists to
  prevent."
  [byencoded]
  (doseq [e (t/sorted-keys byencoded)
          :when (< 1 (count (byencoded e)))]
    (let [pair (vec (sort (byencoded e)))]
      (t/fail "plugin_env_ambiguous"
              (str "refs collide in the environment encoding as " e ": "
                   (str/join ", " pair))
              {"encoded" e "refs" pair}))))

(defn- assoc-path
  "Write one option at a dotted path, creating maps as it goes. A step
  whose current value is not a map is REPLACED, because a scalar written
  by a shallower variable cannot also be a container."
  [m [step & more] value]
  (let [m (if (map? m) m {})]
    (if (empty? more)
      (assoc m step value)
      (assoc m step (assoc-path (t/get m step) more value)))))

(defn- apply-one [out env encoded byencoded reserved key]
  (let [rest (subs key (count prefix))]
    (cond
      (= "PROFILE" rest) (assoc out "profile" (env key))

      (contains? #{"ACTIVE" "INACTIVE"} rest)
      (let [k (if (= "ACTIVE" rest) "active" "inactive")]
        (reduce (fn [acc raw]
                  (let [ref (r/canon-ref raw)]
                    ;; The reservation covers EVERY input layer (section
                    ;; 9.1). VOXGIG_PLUGIN_INACTIVE=station is easier to
                    ;; set than editing a config file, and INACTIVE has
                    ;; the final word - so guarding documents alone would
                    ;; leave the one lever this mechanism exists to deny
                    ;; wide open.
                    (check-reserved ref reserved)
                    (update acc k conj ref)))
                out
                (env-split (env key))))

      :else
      ;; Longest encoded ref first, so `retry$fast` wins over `retry` on
      ;; `RETRY__FAST_MIN`. Shortest-first would read the tag as a path.
      (if-let [enc (first (filter #(or (= rest %) (str/starts-with? rest (str % "_")))
                                  encoded))]
        (let [ref (first (byencoded enc))]
          (check-reserved ref reserved)
          ;; A ref with no path sets nothing.
          (if (= rest enc)
            out
            (let [path (str/split (str/lower-case (subs rest (inc (count enc)))) #"_")]
              (update out "options" assoc ref
                      (assoc-path (t/get (out "options") ref) path
                                  (json/parse-scalar (env key)))))))
        ;; Not for any ref this host holds.
        out))))

(defn apply-env [input]
  (let [env (or (t/get input "env") {})
        refs (map r/canon-ref (or (t/get input "refs") []))
        reserved (or (t/get input "reserved") [])
        byencoded (reduce #(update %1 (encode-ref %2) (fnil conj []) %2) {} refs)]
    (collisions byencoded)
    (let [encoded (t/stable-sort-by #(- (count %)) (t/sorted-keys byencoded))]
      (reduce #(apply-one %1 env encoded byencoded reserved %2)
              {"options" {} "active" [] "inactive" []}
              (filter #(str/starts-with? % prefix) (t/sorted-keys env))))))
