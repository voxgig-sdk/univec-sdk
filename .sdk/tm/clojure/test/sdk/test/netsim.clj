;; Univec SDK netsim tests — the test feature's optional "net" block
;; simulates slow/failing/offline conditions over the mock transport, driven
;; through direct() (needs no entity, so runs for every generated SDK).
(ns sdk.test.netsim
  (:require [sdk.core :as core]
            [sdk.client :as client]
            [sdk.testutil :as t]
            [voxgig.struct :as vs]
            [clojure.string :as str]))

(defn- mget [m k] (when (instance? java.util.Map m) (.get ^java.util.Map m k)))

(defn run [rec]
  (t/run-check rec "netsim-offline-fails"
    (fn [] (let [sdk (client/test-sdk (vs/jm "net" (vs/jm "offline" true)) nil)
                 res (client/direct sdk (vs/jm "path" "/ping"))]
             (t/is-eq (mget res "ok") false "offline fails")
             (t/is-some (mget res "err") "err present"))))

  (t/run-check rec "netsim-fail-status"
    (fn [] (let [sdk (client/test-sdk (vs/jm "net" (vs/jm "failTimes" 1 "failStatus" 503)) nil)
                 res (client/direct sdk (vs/jm "path" "/ping"))]
             (t/is-eq (mget res "ok") false "not ok")
             (t/is-eq (mget res "status") 503 "503"))))

  (t/run-check rec "netsim-error-times-conn"
    (fn [] (let [sdk (client/test-sdk (vs/jm "net" (vs/jm "errorTimes" 1)) nil)
                 res (client/direct sdk (vs/jm "path" "/ping"))]
             (t/is-eq (mget res "ok") false "not ok")
             (t/is-true (boolean (re-find #"(?i)connection error" (core/err-msg (mget res "err")))) "conn error"))))

  (t/run-check rec "netsim-latency-delays"
    (fn [] (let [delay 60
                 sdk (client/test-sdk (vs/jm "net" (vs/jm "latency" delay)) nil)
                 start (System/currentTimeMillis)]
             (client/direct sdk (vs/jm "path" "/ping"))
             (let [elapsed (- (System/currentTimeMillis) start)]
               (t/is-true (>= elapsed (- delay 25)) (str "latency >= " (- delay 25) ", got " elapsed))))))

  (t/run-check rec "netsim-plain-test-sdk-works"
    (fn [] (t/is-some (client/test-sdk nil nil) "sdk created")))
  nil)
