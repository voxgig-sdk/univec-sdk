;; Univec SDK test runner (tools.deps main entry point).
;; Runs the vendored omni runner's smoke test, the API-agnostic suites
;; (primary utility, pipeline, features, netsim), the generated API-specific
;; suite, and the vendored struct corpus, then reports counts and exits
;; non-zero on any failure. `--sdk-only` skips the corpus steps (see -main).
(ns sdk.test-runner
  (:require [sdk.test.primary :as primary]
            [sdk.test.pipeline :as pipeline]
            [sdk.test.feature :as feature]
            [sdk.test.netsim :as netsim]
            [sdk.test.struct-corpus :as corpus]
            [sdk.test.omni-smoke :as omnismoke]
            [sdk.gentest :as gentest]
            [clojure.java.io :as io]))

;; FEATURE SUITES THAT SHIP AS THEIR OWN FILE.
;;
;; A feature whose source ships as its own gated container brings its own
;; suite with it, at sdk/test/feature/<name>.clj. An SDK that did not
;; select the feature has neither file, and most features have no separate
;; suite at all - so the require has to be conditional.
;;
;; IT IS CONDITIONAL ON THE FILES THAT SHIPPED, read off the classpath, and
;; on nothing else. Keying it off the generated wiring instead (sdk.config's
;; feature-extra, or its `feature` map) looks tidier and is a trap: break
;; the wiring and the suite that would have caught it is skipped IN
;; SILENCE, so an SDK sending unauthenticated requests still reports ALL
;; GREEN. With the file as the gate, a shipped suite ALWAYS runs, and a
;; suite that will not load or has no `run` is a recorded FAILURE rather
;; than a skip.
(defn- feature-suite-names []
  (let [url (io/resource "sdk/test/feature")
        dir (when url (try (io/file (.toURI url)) (catch Throwable _ nil)))]
    (if (and dir (.isDirectory ^java.io.File dir))
      (sort (keep (fn [f]
                    (let [n (.getName ^java.io.File f)]
                      (when (.endsWith ^String n ".clj")
                        (subs n 0 (- (count n) 4)))))
                  (seq (.listFiles ^java.io.File dir))))
      [])))

;; POSITIVE EVIDENCE THAT A SUITE RAN.
;;
;; Each suite gets a COUNTING rec, and the runner prints
;; `feature.<name>: ran N check(s)` from that count - the clojure spelling
;; of the `feature.<name>: ran N of M case(s)` line every corpus runner
;; prints, and the line sdkgen's own lane REQUIRES
;; (ts/test/generatedcompile.test.ts, `clojure: the secrets feature runs
;; with the feature active`). Exit zero is not evidence: drop the
;; `(run-feature-suites rec)` call from -main and every check below simply
;; vanishes from the SDK count with ALL GREEN still printed, which is how
;; the secrets suite was once disconnected without a single red. The count
;; is of checks that EXECUTED (one rec per sdk.testutil/run-check), never a
;; declared size, so a stopped engine cannot reproduce it; and a suite that
;; loads, runs and records nothing is a FAILURE, not a pass.
(defn- run-feature-suites [rec]
  (doseq [fname (feature-suite-names)]
    (let [ns-sym (symbol (str "sdk.test.feature." fname))
          suite (str "feature/" fname ":suite")
          ran (atom 0)
          counting (fn [name ok? msg] (swap! ran inc) (rec name ok? msg))
          runfn (try
                  (require ns-sym)
                  (resolve (symbol (str ns-sym) "run"))
                  (catch Throwable e
                    (rec suite false
                         (str "the " fname " feature suite failed to load: "
                              (or (.getMessage e) (str e))))
                    ::failed))]
      (cond
        (= ::failed runfn) nil

        (nil? runfn)
        (rec suite false (str "no " ns-sym "/run in the " fname " feature suite"))

        :else
        (try
          (runfn counting)
          (catch Throwable e
            (rec suite false
                 (str "the " fname " feature suite threw outside a check: "
                      (or (.getMessage e) (str e)))))))
      (println (str "feature." fname ": ran " @ran " check(s)"))
      (when (zero? @ran)
        (rec suite false (str "the " fname " feature suite ran no checks"))))))

(defn- find-corpus-file []
  (first (filter (fn [p] (.exists (java.io.File. ^String p)))
                 ["../.sdk/test/test.json" ".sdk/test/test.json" "../../.sdk/test/test.json" "test/test.json"])))

;; `--sdk-only` runs the SDK's OWN suites and skips the three steps that read
;; the shared corpus (.sdk/test/test.json): the omni smoke test, the primary
;; corpus and the struct corpus. create-sdkgen compiles that corpus into
;; every scaffolded project, so the default run REQUIRES it - a missing
;; corpus is exit 1, never a skip. sdkgen's own CI has no corpus: its lane
;; generates a bare SDK and runs THIS entry point with the flag, which is
;; what makes the feature suites above verifiable there through the same
;; -main a project runs. The skip is printed, never silent.
(defn -main [& args]
  (let [sdk-only? (boolean (some #{"--sdk-only"} args))
        results (atom [])
        rec (fn [name ok? msg] (swap! results conj {:name name :ok ok? :msg msg}))]
    ;; The vendored engine's own smoke test runs FIRST: if the runner cannot
    ;; fail a bad entry, every corpus count below it is meaningless.
    (when-not sdk-only? (omnismoke/run rec))
    (primary/run rec)
    ;; The shared corpus, driven through this SDK's utilities.
    (when-not sdk-only? (primary/run-corpus rec))
    (pipeline/run rec)
    (feature/run rec)
    (run-feature-suites rec)
    (netsim/run rec)
    (gentest/run rec)
    (let [fails (filter (complement :ok) @results)
          np (count (filter :ok @results))
          nf (count fails)]
      (doseq [f fails] (println "FAIL" (:name f) "-" (:msg f)))
      (println (str "SDK: PASS " np "  FAIL " nf))
      (if sdk-only?
        (do (println "STRUCT CORPUS: skipped (--sdk-only)")
            (println (str "TOTAL: PASS " np "  FAIL " nf))
            (flush)
            (if (pos? nf)
              (System/exit 1)
              (println "ALL GREEN")))
        (let [cf (find-corpus-file)]
          (if (nil? cf)
            (do (println "STRUCT CORPUS: test.json not found on any candidate path") (flush) (System/exit 1))
            (let [[cp cfail _] (corpus/run-corpus cf)]
              (println (str "STRUCT CORPUS: PASS " cp "  FAIL " cfail))
              (println (str "TOTAL: PASS " (+ np cp) "  FAIL " (+ nf cfail)))
              (flush)
              (if (or (pos? nf) (pos? cfail))
                (System/exit 1)
                (println "ALL GREEN")))))))))
