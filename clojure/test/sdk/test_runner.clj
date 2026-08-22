;; Univec SDK test runner (tools.deps main entry point).
;; Runs the API-agnostic suites (primary utility, pipeline, features, netsim),
;; the generated API-specific suite, and the vendored struct corpus, then
;; reports counts and exits non-zero on any failure.
(ns sdk.test-runner
  (:require [sdk.test.primary :as primary]
            [sdk.test.pipeline :as pipeline]
            [sdk.test.feature :as feature]
            [sdk.test.netsim :as netsim]
            [sdk.test.struct-corpus :as corpus]
            [sdk.gentest :as gentest]))

(defn- find-corpus-file []
  (first (filter (fn [p] (.exists (java.io.File. ^String p)))
                 ["../.sdk/test/test.json" ".sdk/test/test.json" "../../.sdk/test/test.json" "test/test.json"])))

(defn -main [& _args]
  (let [results (atom [])
        rec (fn [name ok? msg] (swap! results conj {:name name :ok ok? :msg msg}))]
    (primary/run rec)
    (pipeline/run rec)
    (feature/run rec)
    (netsim/run rec)
    (gentest/run rec)
    (let [fails (filter (complement :ok) @results)
          np (count (filter :ok @results))
          nf (count fails)]
      (doseq [f fails] (println "FAIL" (:name f) "-" (:msg f)))
      (println (str "SDK: PASS " np "  FAIL " nf))
      (let [cf (find-corpus-file)]
        (if (nil? cf)
          (do (println "STRUCT CORPUS: test.json not found on any candidate path") (flush) (System/exit 1))
          (let [[cp cfail _] (corpus/run-corpus cf)]
            (println (str "STRUCT CORPUS: PASS " cp "  FAIL " cfail))
            (println (str "TOTAL: PASS " (+ np cp) "  FAIL " (+ nf cfail)))
            (flush)
            (if (or (pos? nf) (pos? cfail))
              (System/exit 1)
              (println "ALL GREEN"))))))))
