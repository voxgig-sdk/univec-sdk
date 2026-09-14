;; VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (clojure/src/voxgig/sekreto/addr.clj)
;; Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
;; Refusing to send a secret-bearing credential in the clear.
;;
;; IN THE CORE, not with the plugins that call it. Every plugin that opens
;; a socket guards its configured address here, and one rule that answers
;; the same in every port is worth more than a rule each store's client
;; carries its own copy of.
;;
;; A port of typescript/src/provider/addr.ts, which is canonical.

(ns voxgig.sekreto.addr
  (:require [clojure.string :as string]
            [voxgig.sekreto.core :as core])
  (:import [java.util Locale]))

(defn- authorityend
  "Where an address's authority ends: the position of the first `/`, `?` or
  `#`, or nil for none. The EARLIEST of the three - looking for them one
  after another instead answers with whichever was asked about first, so
  `http://host?a=/b` would be read as having the authority `host?a=`."
  [text]
  (let [marks (keep (fn [ch] (string/index-of text ch)) ["/" "?" "#"])]
    (when (seq marks) (apply min marks))))

(defn safeaddr
  "An address with any userinfo replaced by `[redacted]`, for messages.

  Every refusal below names the address it refused, and one of them fires
  precisely because the address carries a credential - so printing it
  verbatim wrote the password to stderr and into the logs. It cannot be
  cleaned up afterwards either: that password was never resolved as a
  secret, so redaction has never seen it and never will. The host is what a
  reader needs to identify which chain entry is at fault; the userinfo is
  not."
  [addr]
  (let [mark (string/index-of addr "://")]
    (if (nil? mark)
      addr
      (let [rest (subs addr (+ mark 3))
            stop (authorityend rest)
            authority (if (nil? stop) rest (subs rest 0 stop))
            at (string/last-index-of authority "@")]
        (if (nil? at)
          addr
          (str (subs addr 0 (+ mark 3)) "[redacted]" (subs addr (+ mark 3 at))))))))

(defn checkaddr
  "Refuse to send a secret-bearing credential in the clear.

  A vault API is HTTPS in any real deployment; plaintext is a dev-mode
  convenience. Sending a token over http to anything but the local machine
  puts both the token and the secret it fetches on the wire for anyone on
  the path, so sekreto will not do it. Loopback stays allowed: that is
  `vault server -dev`, `boru vault serve`, and this repo's own test harness.

  The address is read by hand, in the same handful of steps in every port,
  rather than by each platform's URL parser. That is deliberate. A dozen
  parsers disagree about malformed input - where userinfo ends, whether
  `0177.0.0.1` is loopback, what an unclosed bracket means - and a check
  that answers differently in different ports is not a check.

  The rule this parse obeys, and the reason it can be trusted: it is never
  more permissive than the HTTP client that will dial the address. It ends
  the authority at `/`, `?` or `#` only, so a client that also breaks on
  `\\` (WHATWG does) can only ever see a SHORTER host than this does. It
  refuses userinfo outright rather than locating its end. It compares the
  host literally, so a numeric form no parser here agrees on is refused
  rather than guessed at."
  [addr]
  (let [scheme (cond
                 (string/starts-with? addr "https://") "https://"
                 (string/starts-with? addr "http://") "http://"
                 :else (throw (core/sekretoerror
                               (str "sekreto: not an http(s) address: " (safeaddr addr)))))
        rest (subs addr (count scheme))
        stop (authorityend rest)
        authority (if (nil? stop) rest (subs rest 0 stop))]

    ;; Userinfo is refused outright rather than parsed around, and on https
    ;; as well as http. No store this library speaks authenticates by
    ;; userinfo - they take a token or a signature - so an address carrying
    ;; one is a mistake at best. At worst it is the attack this whole
    ;; function exists to stop: `http://localhost:8200@evil.example.com/` is
    ;; a request to evil.example.com that reads, to anything that splits the
    ;; authority on ':', as loopback.
    (when (string/includes? authority "@")
      (throw (core/sekretoerror
              (str "sekreto: refusing an address with embedded credentials: " (safeaddr addr)))))

    ;; An opening bracket with no closing one is not an address at all.
    (when (and (string/starts-with? authority "[") (not (string/includes? authority "]")))
      (throw (core/sekretoerror
              (str "sekreto: not a valid http(s) address: " (safeaddr addr)))))

    (when (not= "https://" scheme)
      ;; A bracketed IPv6 literal keeps its brackets. Splitting the
      ;; authority on the first colon yields '[', so `http://[::1]:8200`
      ;; could never match - which made the '[::1]' entry below unreachable,
      ;; and refused a legitimate local vault.
      (let [host (.toLowerCase
                  ^String (if (string/starts-with? authority "[")
                            (subs authority 0 (inc (string/index-of authority "]")))
                            (apply str (take-while (fn [ch] (not= \: ch)) authority)))
                  Locale/ROOT)]
        (when-not (contains? #{"localhost" "127.0.0.1" "::1" "[::1]"} host)
          (throw (core/sekretoerror
                  (str "sekreto: refusing to send a token in plaintext to "
                       (safeaddr addr) " (use https)"))))))))

