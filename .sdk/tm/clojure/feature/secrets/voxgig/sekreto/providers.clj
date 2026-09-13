;; VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (clojure/src/voxgig/sekreto/providers.clj)
;; Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
;; What a provider is, how a provider kind becomes a voxgig/plugin
;; definition - and the four BUILT-IN kinds.
;;
;; A provider answers one question: "do you have this secret?" It returns
;; the value, or nil to mean "ask the next one". Nothing else about a
;; provider is visible to the caller - which is the point: an app reads
;; `api.token` and never learns whether it came from the environment, a
;; .env file, HashiCorp Vault or a boru vault.
;;
;; Two failure shapes, and they are never interchangeable. A store that does
;; not hold the secret is a MISS (nil) - the chain carries on. A store that
;; could not answer - bad credentials, unreachable host, missing
;; configuration - is an ERROR, because falling through there would quietly
;; reach for a weaker store.
;;
;; THIS NAMESPACE IMPORTS NO HTTP CLIENT, NO HASH FUNCTION AND NO
;; ProcessBuilder. What makes a kind built in is that it needs nothing of
;; the platform beyond reading a local file; every kind that opens a
;; socket, signs a request or spawns a process is a plugin under
;; `plugins/`, its own namespace, required only by a program that names it
;; (docs/design/plugin-providers.md).
;;
;; A port of typescript/src/provider/support.ts and
;; typescript/src/provider/builtin.ts, which are canonical.

(ns voxgig.sekreto.providers
  (:require [clojure.string :as string]
            [voxgig.sekreto.core :as core]
            [voxgig.sekreto.provider :as provider]
            [voxgig.plugin.host :as host]
            [voxgig.plugin.types :as plugintypes])
  (:import [java.io IOException]
           [java.nio.charset StandardCharsets]
           [java.nio.file Files LinkOption NoSuchFileException Path Paths]))

(defn path-of ^Path [& parts]
  (Paths/get ^String (first parts) ^"[Ljava.lang.String;" (into-array String (rest parts))))

(defn absent?
  "Does this read failure mean \"no secrets here\", rather than \"I could
  not answer\"?

  Absence is a MISS and the chain carries on; anything else - permission
  denied, an unreadable mount, a failing disk - is an ERROR, because
  returning a miss there falls silently through to a weaker store.

  Asked of the directory, not of the file. The obvious spelling, \"the file
  does not exist\", is wrong in exactly the case the rule exists for: that
  question is \"did the access check throw\", so it answers *no* for a
  permission failure and turned a locked directory - the canonical
  \"unreadable mount\" - into a miss. A path whose parent is a plain file
  really is \"no secrets here\", and that is what this asks. The reason
  string is not consulted: it comes from the C library's strerror and
  follows the machine's locale."
  [^Path file]
  (let [dir (.getParent file)]
    (and (some? dir) (not (Files/isDirectory dir (make-array LinkOption 0))))))

(defn readfile
  "A file's whole text, or nil when there is simply no file there.

  Reading a local file is the whole of what a built-in kind is allowed to
  do, which is why this lives here and not with the plugins - though the
  hashicorp plugin reads its Kubernetes service-account JWT through it."
  [^Path file what]
  (try
    (String. (Files/readAllBytes file) StandardCharsets/UTF_8)
    ;; An absent file - or an absent directory - means "no secrets here".
    (catch NoSuchFileException _ nil)
    (catch IOException err
      (if (absent? file)
        nil
        (throw (core/sekretoerror (str "sekreto: " what " cannot read " file ": "
                                       (.getMessage err))))))))

;; ------------------------------------------------------------- the builtins
;;
;; What makes a kind built in is that it reads at most a local file: it
;; opens no socket, signs no request and spawns no process.

(defrecord Env [prefix source]
  provider/Provider

  (lookup [_ name]
    (let [key (core/envkey name prefix)]
      (if (nil? source) (core/getenv key) (get source key))))

  (describe [_]
    (str "env" (when (core/notempty prefix) (str ":" prefix)))))

(defrecord Dotenv [file prefix values]
  provider/Provider

  (lookup [_ name]
    ;; Read once. A file that was not there when the chain was built is not
    ;; read again either: a missing .env means "no secrets here", and
    ;; re-reading it on every lookup would make a chain's answers depend on
    ;; when it was asked.
    (get (or @values (reset! values (core/parsedotenv (readfile (path-of file) "dotenv provider"))))
         (core/envkey name prefix)))

  (describe [_] (str "dotenv:" file)))

(defrecord Memory [values prefix]
  provider/Provider

  (lookup [_ name] (get values (core/envkey name prefix)))

  (describe [_]
    (str "memory" (when (core/notempty prefix) (str ":" prefix)))))

(defrecord Filedir [dir prefix]
  provider/Provider

  ;; A directory of one-secret-per-file entries, keyed like the environment:
  ;; `api.token` reads `<dir>/API_TOKEN`.
  ;;
  ;; This is the shape of a mounted Kubernetes Secret, a Docker or Swarm
  ;; secret, and a systemd credentials directory, so those all work with no
  ;; further configuration. One trailing newline is stripped - tools that
  ;; write these files disagree about it, and a newline is never part of a
  ;; secret on purpose.
  (lookup [_ name]
    (when-let [text (readfile (path-of dir (core/envkey name prefix)) "file provider")]
      (cond
        (string/ends-with? text "\r\n") (subs text 0 (- (count text) 2))
        (string/ends-with? text "\n") (subs text 0 (dec (count text)))
        :else text)))

  (describe [_] (str "file:" dir)))

;; ------------------------------- providers as voxgig/plugin definitions

;; The export key under which a provider definition publishes the provider
;; it built. `voxgig.sekreto.chain` reads `<ref>/provider` off the host.
(def PROVIDER-EXPORT "provider")

;; The voxgig/plugin error code a sekreto error travels under when it is
;; raised inside a definition's `define`.
;;
;; plugin wraps a code-less error raised by a callback as
;; `plugin_define_failed`, and keeps an error that already carries a code.
;; A provider that refuses its own configuration - `kv: 3`, a missing
;; project - raises a sekreto error, and that message is pinned by the spec
;; byte for byte, so it must come back out of the host exactly as it went
;; in. `providerplugin` gives it this code on the way in; the chain turns
;; it back into a sekreto error on the way out.
(def ERROR-CODE "sekreto_error")

(defn providerplugin
  "A provider kind, as a voxgig/plugin definition.

  This is the whole bridge between the two libraries. The definition's
  `name` is the `kind` a spec names; its `define` reads the spec as the
  instance's options, builds the provider with `make`, and exports it.
  Nothing runs at `activate`: a provider opens nothing until its first
  lookup, so there is nothing to capture - a provider that does hold a
  resource acquires it there and lets the instance scope unwind it.

  Every built-in and every plugin is made this way, so a custom provider
  kind is one call:

    (providerplugin \"mystore\" (fn [spec] (mystore (:addr spec))))"
  [kind make]
  {"name" kind
   "define" (fn [inst]
              (let [built (try
                            (make (host/inst-options inst))
                            (catch clojure.lang.ExceptionInfo err
                              (if (core/sekretoerror? err)
                                (plugintypes/fail ERROR-CODE (ex-message err)
                                                  {"ref" (host/inst-ref inst)
                                                   "cause" (ex-message err)})
                                (throw err))))]
                (host/export! inst PROVIDER-EXPORT built)))})

(def BUILTINS
  "The four built-in provider kinds - the same four in every port. What
  makes a kind built in is that it needs nothing of the platform beyond
  reading a local file: no socket, no TLS, no crypto, no child process."
  [(providerplugin "env" (fn [spec] (->Env (:prefix spec) nil)))
   (providerplugin "memory" (fn [spec] (->Memory (or (:values spec) {}) (:prefix spec))))
   (providerplugin "dotenv" (fn [spec]
                              (->Dotenv (or (core/notempty (:file spec)) ".env")
                                        (:prefix spec) (atom nil))))
   (providerplugin "file" (fn [spec] (->Filedir (or (:dir spec) "") (:prefix spec))))])

(def KINDS
  "Every kind this library ships, built in or as a plugin, so that an
  unknown kind can be told from a plugin that was not loaded."
  {:builtin ["env" "memory" "dotenv" "file"]
   :plugin ["hashicorp" "boru" "awssecrets" "awsparams" "gcpsecrets"
            "azuresecrets" "onepassword" "doppler" "infisical" "secretspec"]})
