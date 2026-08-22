;; Univec SDK test utilities (shared assertion + reporting helpers).
(ns sdk.testutil
  (:require [voxgig.struct :as vs]
            [sdk.core :as core]))

(defn fail! [msg] (throw (ex-info (str msg) {:test-fail true})))

(defn is-true [v msg] (when-not v (fail! (str "expected truthy: " msg))) true)
(defn is-false [v msg] (when v (fail! (str "expected falsey: " msg))) true)
(defn is-nil [v msg] (when (some? v) (fail! (str "expected nil, got " (pr-str v) ": " msg))) true)
(defn is-some [v msg] (when (nil? v) (fail! (str "expected non-nil: " msg))) true)
(defn is-eq [a b msg] (when-not (= a b) (fail! (str "expected " (pr-str b) ", got " (pr-str a) ": " msg))) true)

(defn canon [v]
  (cond
    (vs/ismap v) (into (sorted-map) (map (fn [k] [(str k) (canon (.get ^java.util.Map v k))]) (vs/keysof v)))
    (vs/islist v) (mapv canon (vec v))
    :else v))

(defn deep-eq [a b] (= (canon a) (canon b)))
(defn is-deep [a b msg] (when-not (deep-eq a b) (fail! (str "expected " (pr-str (canon b)) ", got " (pr-str (canon a)) ": " msg))) true)

(defn is-throws [thunk code msg]
  (let [thrown (try (thunk) ::no-throw (catch Throwable e e))]
    (cond
      (= thrown ::no-throw) (fail! (str "expected throw: " msg))
      (nil? code) true
      :else (let [e (core/ex->sdk thrown)]
              (when-not (and e (= (:code e) code)) (fail! (str "expected error code " code ", got " (pr-str (when e (:code e))) ": " msg)))
              true))))

;; Run a single named check; record pass/fail via rec (fn [name ok? msg]).
(defn run-check [rec name thunk]
  (try (thunk) (rec name true nil)
       (catch Throwable e (rec name false (or (.getMessage e) (str e))))))
