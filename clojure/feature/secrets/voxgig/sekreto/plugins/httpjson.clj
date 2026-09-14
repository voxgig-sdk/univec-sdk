;; VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (clojure/plugins/voxgig/sekreto/plugins/httpjson.clj)
;; Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
;; The HTTP-JSON edge every plugin that speaks to a store shares - and
;; NOTHING IN THE CORE REACHES IT.
;;
;; A chain of the four built-in kinds never loads this namespace, so it
;; never loads `java.net.http` either. That is the whole point of the
;; core/plugin split: an app whose chain is `[dotenv env]` carries no
;; HTTP client at all (docs/design/plugin-providers.md).
;;
;; `uriescape` lives here rather than with sigv4 because four plugins
;; that sign nothing need it to build a query string, and reaching it
;; through sigv4 would make them load a hash function to escape a
;; parameter.
;;
;; A port of typescript/plugins/httpjson.ts, which is canonical.

(ns voxgig.sekreto.plugins.httpjson
  (:require [voxgig.sekreto.core :as core]
            [voxgig.sekreto.json :as json])
  (:import [java.io ByteArrayOutputStream IOException]
           [java.net URI]
           [java.net.http HttpClient HttpClient$Redirect HttpClient$Version
            HttpRequest HttpRequest$BodyPublishers HttpResponse HttpResponse$BodyHandlers]
           [java.nio.charset StandardCharsets]
           [java.time Duration]))

;; How long any single vault round-trip may take before it is treated as
;; unreachable. Ports carry the same bound.
(def ^:private TIMEOUT (Duration/ofSeconds 10))

;; How much of a response body will be read before the store is treated as
;; having answered incoherently. Ports carry the same bound.
;;
;; Far above anything real - the largest legitimate payload this library
;; fetches is Doppler's whole-config download, measured in kilobytes. A
;; bound is needed because the TIMEOUT is not one: ten seconds on a loopback
;; or datacentre link is gigabytes, and the body is accumulated in memory
;; before it is parsed. This runs on an application's startup path, so the
;; failure is the application never starting.
(def ^:private MAXBODY (* 8 1024 1024))

(defn firstof
  "The first candidate that is set and non-empty, or the empty string.
  Config first, then the environment variable the store's own ecosystem
  already uses, is how every plugin here reads its settings."
  [& candidates]
  (or (some core/notempty candidates) ""))

(defn trimslash [text] (core/dropsuffix text "/"))

;; HTTP/1.1, explicitly.
;;
;; java.net.http defaults to HTTP_2, and over cleartext that means an h2c
;; upgrade: the first request goes out with `Upgrade: h2c`, the declared
;; Content-Length, and NO BODY, and the body follows only after the server
;; declines. A server that checks the two against each other - Fastify does,
;; and Infisical is Fastify - rejects that request outright with "Request
;; body size did not match Content-Length", so every POST this port makes to
;; such a server fails before it is even read.
;;
;; The mocks in test/ are Node's own http module, which does not object,
;; which is why this survived until the same code met a real Infisical. No
;; vault API this library speaks needs HTTP/2.
;;
;; Redirects are never followed: a vault API does not legitimately redirect,
;; and a followed redirect would carry X-Vault-Token to the redirect's host
;; (and could downgrade https to http), which checkaddr - it only validates
;; the configured address - cannot see.
;;
;; A delay, so that requiring this namespace opens no resources: the client
;; is built by the first fetch, in a process that has one to make.
(def ^:private CLIENT
  (delay (-> (HttpClient/newBuilder)
             (.version HttpClient$Version/HTTP_1_1)
             (.followRedirects HttpClient$Redirect/NEVER)
             (.connectTimeout TIMEOUT)
             (.build))))

(defn- why
  "What an exception has to say for itself, never the empty string."
  [^Throwable err]
  (or (core/notempty (.getMessage err)) (str err)))

(defn bare
  "A URL without its query string, for a message that must not leak one."
  [url]
  (apply str (take-while (fn [ch] (not= \? ch)) url)))

(defn uriescape
  "RFC 3986 escaping, which is stricter than the usual URL encoder: AWS
  wants everything but unreserved characters escaped, with uppercase hex."
  [^String text]
  (let [out (StringBuilder.)]
    (doseq [byte (.getBytes text StandardCharsets/UTF_8)]
      (let [ch (bit-and (int byte) 0xff)]
        (if (or (<= (int \A) ch (int \Z))
                (<= (int \a) ch (int \z))
                (<= (int \0) ch (int \9))
                (= (int \-) ch) (= (int \_) ch) (= (int \.) ch) (= (int \~) ch))
          (.append out (char ch))
          (.append out (format "%%%02X" ch)))))
    (.toString out)))

(defn- hexbyte
  "Two hex digits as a byte, or nil. The usual number reads are decimal."
  [^String text]
  (try (Integer/parseInt text 16) (catch NumberFormatException _ nil)))

(defn uridecode
  "Percent-decode, and nothing else: `+` stays `+`, as on the wire."
  [^String text]
  (let [out (ByteArrayOutputStream.)]
    (loop [index 0]
      (if (<= (count text) index)
        (String. (.toByteArray out) StandardCharsets/UTF_8)
        (let [head (.charAt text index)
              code (when (and (= \% head) (> (count text) (+ index 2)))
                     (hexbyte (subs text (inc index) (+ index 3))))]
          (if (some? code)
            (do (.write out (int code))
                (recur (+ index 3)))
            ;; A stray % is kept as-is, the way a browser would.
            (do (.write out (.getBytes (str head) StandardCharsets/UTF_8))
                (recur (inc index)))))))))

(defn fetchjson
  "One JSON round-trip: `{:status <int> :body <json>}`, where the body is
  `json/NONE` when there was nothing readable. Network failure is always an
  error - an unreachable store is a store that could not answer."
  ([method url] (fetchjson method url {} nil))
  ([method url headers] (fetchjson method url headers nil))
  ([method url headers body]
   (let [builder (doto (HttpRequest/newBuilder)
                   (.uri (URI/create url))
                   (.timeout TIMEOUT)
                   (.method method (if (nil? body)
                                     (HttpRequest$BodyPublishers/noBody)
                                     (HttpRequest$BodyPublishers/ofString
                                      body StandardCharsets/UTF_8))))

         _ (doseq [[key value] headers] (.header builder key value))

         ;; ofInputStream, not ofString: ofString buffers whatever arrives,
         ;; so an endless body would be accumulated in memory until the
         ;; deadline - which on a loopback or datacentre link is gigabytes.
         response (try
                    (.send ^HttpClient @CLIENT (.build builder)
                           (HttpResponse$BodyHandlers/ofInputStream))
                    ;; A refused connection arrives with a null message, so
                    ;; the class name stands in - "cannot reach ...: null"
                    ;; says nothing at all.
                    (catch IOException err
                      (throw (core/sekretoerror
                              (str "sekreto: cannot reach " (bare url) ": " (why err)))))
                    (catch InterruptedException _
                      (.interrupt (Thread/currentThread))
                      (throw (core/sekretoerror
                              (str "sekreto: cannot reach " (bare url) ": interrupted")))))

         ^java.io.InputStream stream (.body ^HttpResponse response)

         ;; One byte over the bound is enough to know it was exceeded. An
         ;; endless body is a store that could not answer, so this raises
         ;; rather than returning a miss - the latter would fall through to
         ;; a weaker store on an attacker's cue.
         text (try
                (let [raw (.readNBytes stream (inc MAXBODY))]
                  (when (< MAXBODY (alength raw))
                    (throw (core/sekretoerror (str "sekreto: oversized response from " (bare url)))))
                  (String. raw StandardCharsets/UTF_8))
                (catch IOException err
                  (throw (core/sekretoerror
                          (str "sekreto: cannot reach " (bare url) ": " (why err)))))
                (finally (.close stream)))

         parsed (json/parse text)]

     ;; A success status promised JSON; a body that does not parse means the
     ;; store could not answer coherently, and treating it as a miss would
     ;; fall through to a weaker store. Error statuses may carry any body -
     ;; they are decided on status alone.
     (when (and (= 200 (.statusCode ^HttpResponse response)) (json/none? parsed))
       (throw (core/sekretoerror (str "sekreto: malformed response from " (bare url)))))

     {:status (.statusCode ^HttpResponse response) :body parsed})))

(defn renewtime
  "When a logged-in token must be renewed, from its expiry in seconds (a
  JSON number, or a string as Azure IMDS sends it): now + max(seconds - 60,
  1). A missing or zero expiry means never renew."
  [expires]
  (let [seconds (cond
                  (json/asnum expires) (double expires)
                  (string? expires) (or (parse-double expires) 0.0)
                  :else 0.0)]
    (if (or (Double/isNaN seconds) (>= 0 seconds))
      Long/MAX_VALUE
      (+ (System/currentTimeMillis) (long (* 1000 (max (- seconds 60) 1.0)))))))

(defn withtoken
  "The working token. `state` is an atom holding `{:token :renewat}`: a
  configured token is kept forever, a logged-in one is renewed shortly
  before its lease runs out - a long-running process must not keep
  presenting a token the vault already expired. `login` answers
  `[token renewat]`."
  [state login]
  (let [{:keys [token renewat]} @state]
    (if (and (some? token) (> (or renewat Long/MAX_VALUE) (System/currentTimeMillis)))
      token
      (let [[fresh until] (login)]
        (reset! state {:token fresh :renewat until})
        fresh))))
