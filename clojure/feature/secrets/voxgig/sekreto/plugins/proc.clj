;; VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (clojure/plugins/voxgig/sekreto/plugins/proc.clj)
;; Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
;; Running a child to completion, for the two kinds that read a secret
;; through somebody else's CLI - boru and secretspec.
;;
;; OUTSIDE THE CORE, because spawning a process is one of the three things
;; that make a kind a plugin. A chain of built-ins never loads this
;; namespace and so never reaches `ProcessBuilder`
;; (docs/design/plugin-providers.md).
;;
;; A port of java/plugins/com/voxgig/sekreto/plugins/Proc.java, which
;; carries the same two-stream rule.

(ns voxgig.sekreto.plugins.proc
  (:require [clojure.string :as string]
            [voxgig.sekreto.core :as core])
  (:import [java.io ByteArrayOutputStream IOException]
           [java.nio.charset StandardCharsets]))

(defn runcmd
  "Run a child to completion and collect both its streams.

  The two streams are drained CONCURRENTLY. Reading stdout to EOF and only
  then reading stderr deadlocks the moment the child writes more than one
  pipe buffer (64 KiB on Linux) to stderr: the parent is blocked waiting for
  stdout, the child is blocked waiting for room on stderr, and neither can
  move. Nothing in this library sets a timeout, so that hang is permanent -
  `get` simply never returns. secretspec's diagnostics are box-drawn and
  reach that size easily.

  The child's stdin is closed rather than left open on a pipe nobody writes
  to, so a CLI that reads it - one prompting for a passphrase when its
  environment variable is absent - sees EOF and gives up instead of waiting
  forever."
  [^ProcessBuilder builder command]
  (try
    (let [process (.start builder)]
      (.close (.getOutputStream process))

      (let [errbuf (ByteArrayOutputStream.)
            pump (fn []
                   (try
                     (.transferTo (.getErrorStream process) errbuf)
                     ;; The child went away mid-write; waitFor reports how.
                     (catch IOException _ nil)))
            drain (doto (Thread. ^Runnable pump) (.setDaemon true) (.start))
            out (String. (.readAllBytes (.getInputStream process)) StandardCharsets/UTF_8)
            status (.waitFor process)]
        (.join drain)
        {:out out
         :why (string/trim (String. (.toByteArray errbuf) StandardCharsets/UTF_8))
         :status status}))
    (catch IOException err
      (throw (core/sekretoerror (str "sekreto: cannot run " command ": " (.getMessage err)))))
    (catch InterruptedException _
      (.interrupt (Thread/currentThread))
      (throw (core/sekretoerror (str "sekreto: interrupted running " command))))))

(defn command
  "A ProcessBuilder for an argument vector."
  ^ProcessBuilder [args]
  (ProcessBuilder. ^"[Ljava.lang.String;" (into-array String args)))
