;; Univec SDK omni runner smoke test.
;;
;; Smoke tests for the VENDORED omni runner itself: a runner that cannot FAIL a
;; bad entry would turn every corpus suite vacuously green, so the failure
;; paths are pinned here, not just the happy one. (Clojure peer of lua's
;; test/omni_smoke_test.lua and ts's test/omni.test.ts.)
(ns sdk.test.omni-smoke
  (:require [sdk.test.omni :as omni]
            [sdk.testutil :as t]
            [clojure.string :as str]))


;; A minimal in-memory spec: no fixture file, no OMNI block (lenient v0, like
;; the shared corpus). Built in omni's own value model - immutable clojure
;; maps and vectors, which is what its walkers recognise.
(defn- makespec []
  (array-map
   "primary"
   (array-map
    "smoke"
    (array-map
     "basic" (array-map "set" [(array-map "in" 1 "out" 2)
                               (array-map "in" 41 "out" 42)])
     "bad"   (array-map "set" [(array-map "in" 1 "out" 999)])
     "err"   (array-map "set" [(array-map "in" 0 "err" "zero refused")])))))


(defn- inc-subject [n]
  (when (zero? n) (throw (ex-info "smoke: zero refused" {})))
  (inc n))


(defn- pack [] ((omni/make-runner (makespec)) "smoke"))


;; Run `thunk`, requiring it to raise an omni FAILURE whose message contains
;; `want`. A plain exception is not enough: it must be omni's own error type,
;; or the suite is catching something the runner never meant as a verdict.
(defn- must-fail [thunk want]
  (let [outcome (try (thunk) ::no-throw (catch Throwable e e))]
    (when (= ::no-throw outcome)
      (t/fail! (str "expected the runner to FAIL, but it passed: " want)))
    (when-not (omni/omni-error? outcome)
      (t/fail! (str "expected an omni error, got: " (pr-str outcome))))
    (let [msg (str (ex-message outcome))]
      (when-not (str/includes? msg want)
        (t/fail! (str "expected failure containing '" want "', got: " msg))))
    true))


(defn run [rec]
  (t/run-check rec "omni-smoke-passes-a-correct-subject"
    (fn []
      (let [p (pack)]
        ((:runset p) (get (:spec p) "basic") inc-subject))))

  (t/run-check rec "omni-smoke-fails-a-wrong-result"
    (fn []
      (let [p (pack)]
        (must-fail (fn [] ((:runset p) (get (:spec p) "bad") inc-subject))
                   "result mismatch"))))

  (t/run-check rec "omni-smoke-matches-an-expected-error"
    (fn []
      (let [p (pack)]
        ((:runset p) (get (:spec p) "err") inc-subject))))

  (t/run-check rec "omni-smoke-fails-a-missing-expected-error"
    (fn []
      (let [p (pack)]
        (must-fail (fn [] ((:runset p) (get (:spec p) "err") identity))
                   "expected error did not occur"))))

  ;; The engine must be reachable through the SAME entry point the corpus
  ;; suites use, over the SAME spec file - a smoke test that only ever sees an
  ;; in-memory spec cannot notice a broken spec path.
  (t/run-check rec "omni-smoke-loads-the-shared-corpus"
    (fn []
      (let [p ((omni/make-runner "../.sdk/test/test.json") "struct")]
        (t/is-true (map? (:spec p)) "the struct corpus section did not load")
        (t/is-true (some? (get (:spec p) "minor")) "the struct corpus has no minor section")))))
