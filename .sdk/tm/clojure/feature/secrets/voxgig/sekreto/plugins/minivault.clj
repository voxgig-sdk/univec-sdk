;; VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (clojure/plugins/voxgig/sekreto/plugins/minivault.clj)
;; Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
;; The mini vault, as a voxgig/plugin definition.
;;
;; A plugin rather than a built-in kind because it needs crypto, and a
;; built-in kind reads at most a local file
;; (docs/design/plugin-providers.md).
;;
;; THE KEY DECIDES WHAT THE VAULT HOLDS. A master key reads and writes
;; every name and mints restricted keys. A restricted key reads the names
;; it was granted and CANNOT DERIVE ANY OTHER - the restriction is the
;; cryptography rather than a check this code performs. What that does and
;; does not protect is set out in DOCS.md under "What the mini vault
;; protects".
;;
;; `javax.crypto` carries all four primitives, so nothing here is
;; hand-rolled (AGENTS.md rule 3).
;;
;; A port of typescript/plugins/minivault.ts, which is canonical.

(ns voxgig.sekreto.plugins.minivault
  (:require [voxgig.sekreto.core :as core]
            [voxgig.sekreto.json :as json]
            [voxgig.sekreto.provider :as provider]
            [voxgig.sekreto.providers :as providers]
            [voxgig.plugin.host :as host]
            [voxgig.plugin.types :as plugintypes])
  (:import [java.io ByteArrayOutputStream File]
           [java.nio ByteBuffer]
           [java.nio.charset StandardCharsets]
           [java.nio.file FileAlreadyExistsException Files NoSuchFileException Path
            StandardCopyOption StandardOpenOption]
           [java.nio.file.attribute PosixFilePermissions]
           [java.security GeneralSecurityException SecureRandom]
           [java.util Arrays Base64]
           [javax.crypto Cipher Mac SecretKeyFactory]
           [javax.crypto.spec GCMParameterSpec PBEKeySpec SecretKeySpec]))

;; --- the format ------------------------------------------------------
;;
;;   magic       4   'SKMV'
;;   version     1   FORMAT
;;   kdf         1   1 = PBKDF2-HMAC-SHA256
;;   cipher      1   1 = AES-256-GCM
;;   reserved    1   0
;;   keycount    4   uint32
;;   per key:
;;     id        1 + bytes      the key id, PLAINTEXT
;;     salt      1 + bytes
;;     iters     4              PBKDF2 rounds for this key
;;     ring      1 + iv, 4 + bytes    sealed under the passphrase
;;     meta      1 + iv, 4 + bytes    sealed under the vault's meta key
;;   entrycount  4   uint32
;;   per entry:
;;     id        1 + bytes      the blinded lookup id
;;     name      1 + iv, 4 + bytes    sealed under the vault's name key
;;     value     1 + iv, 4 + bytes    sealed under that secret's own key
;;
;; Integers are big-endian, and every length precedes its bytes. A file one
;; port writes is read by every other; `test/fixture` pins that with a
;; committed vault rather than with agreement.

(def ^:private MAGIC "SKMV")
(def ^:private FORMAT 1)
(def ^:private KDF-PBKDF2 1)
(def ^:private CIPHER-AESGCM 1)

;; AES-256-GCM: 32-byte keys, 12-byte nonces, 16-byte tags.
(def ^:private KEYLEN 32)
(def ^:private IVLEN 12)
(def ^:private TAGLEN 16)
(def ^:private SALTLEN 16)

(def ITERATIONS
  "PBKDF2-HMAC-SHA256 rounds when a caller names none."
  210000)

(def MASTERKEY
  "The key id a vault gets when a caller names none."
  "master")

;; Additional authenticated data. Every blob is bound to its PLACE in the
;; file, so no ciphertext can be moved.
(def ^:private AAD-RING "skmv1:ring:")
(def ^:private AAD-META "skmv1:meta:")
(def ^:private AAD-NAME "skmv1:name")
(def ^:private AAD-SECRET "skmv1:secret:")

;; Everything a master can reach is derived from the root key, so a
;; rotation is one new random value rather than a re-wrap of each part.
(def ^:private LABEL-NAMES "skmv1:names")
(def ^:private LABEL-META "skmv1:meta")
(def ^:private LABEL-ID "skmv1:id")

(def ^:private IDMAX
  ;; `small` writes a length in ONE byte. A longer id wrapped that byte and
  ;; the writer then appended the whole thing, so every field after it
  ;; shifted. Checked where an id is ACCEPTED, so the refusal names the id
  ;; rather than the file.
  255)

(def VAULT-EXPORT
  "The export key the vault API is published under, beside `provider`."
  "vault")

(def ^:private RANDOM (SecureRandom.))

(defn- fail [text]
  (throw (core/sekretoerror (str "sekreto: minivault: " text))))

(defn- utf8 ^bytes [^String text]
  (.getBytes text StandardCharsets/UTF_8))

;; THE LOCK EVERY HANDLE ON ONE FILE SHARES.
;;
;; Each handle is its own map, so two handles on one path did not
;; coordinate: both could finish `vaultload` before either saved, and the
;; second rename then discarded the first one's change while reporting
;; success. Keyed by the ABSOLUTE path, so two handles spelled
;; differently still meet.
;;
;; A guarantee WITHIN one process, which is what DOCS.md promises and what
;; the go port arranges the same way. Two processes still race, and the
;; format's answer to that is the exclusive create and the atomic rename:
;; a reader sees one whole vault or the other, never half of one.
(defonce ^:private LOCKS (atom {}))

(defn- lockfor [file]
  (let [key (try (.getPath (.getCanonicalFile (File. ^String file)))
                 (catch Exception _ file))]
    (or (get @LOCKS key)
        (get (swap! LOCKS (fn [held] (if (contains? held key)
                                       held
                                       (assoc held key (Object.)))))
             key))))

(defn- wantkey
  "The key a caller asked for, or `MASTERKEY`: an EMPTY key is no key.

  The canonical's `opts.key || MASTERKEY` answers for both nil and empty,
  where clojure's `or` answers for nil alone - `\"\"` is truthy here. A
  CLI reaches this with SEKRETO_VAULT_KEY set and empty, which is what an
  unset shell variable expands to."
  [value]
  (if (or (nil? value) (= "" value)) MASTERKEY value))

(defn- checkid [id what]
  (when-not (and (string? id) (not= "" id))
    (fail what))
  (when (< IDMAX (alength (utf8 id)))
    (fail (str "key id is longer than " IDMAX " bytes: " (subs id 0 (min 32 (count id))) "...")))
  id)

;; --- keys ------------------------------------------------------------

(defn- hmac ^bytes [^bytes key ^String text]
  (try
    (let [mac (Mac/getInstance "HmacSHA256")]
      (.init mac (SecretKeySpec. key "HmacSHA256"))
      (.doFinal mac (utf8 text)))
    (catch GeneralSecurityException err
      (fail (str "hmac: " (.getMessage err))))))

(defn- kek
  "The key-encryption key a passphrase unwraps a ring with."
  ^bytes [^String passphrase ^bytes salt ^long iters]
  (try
    (-> (SecretKeyFactory/getInstance "PBKDF2WithHmacSHA256")
        (.generateSecret (PBEKeySpec. (.toCharArray passphrase) salt (int iters) (* KEYLEN 8)))
        (.getEncoded))
    (catch GeneralSecurityException err
      (fail (str "pbkdf2: " (.getMessage err))))))

(defn- secretkey
  "The key one named secret's value is encrypted with.

  DERIVED, never stored, for a master: it holds the root key and so reaches
  every name, including ones written after it was made. A restricted key
  holds the derived keys it was granted and nothing that produces another."
  ^bytes [^bytes root ^String name]
  (hmac root (str AAD-SECRET name)))

(defn- entryid
  "Where a secret lives in the file, derived from its own key so that
  finding it needs no plaintext name."
  ^bytes [^bytes key]
  (hmac key LABEL-ID))

(defn- randombytes ^bytes [^long len]
  (let [out (byte-array len)]
    (.nextBytes RANDOM out)
    out))

;; --- sealing ---------------------------------------------------------

(defn- seal
  "A nonce and the ciphertext with its tag appended."
  [^bytes key ^bytes plain ^String aad]
  (try
    (let [iv (randombytes IVLEN)
          cipher (Cipher/getInstance "AES/GCM/NoPadding")]
      (.init cipher Cipher/ENCRYPT_MODE (SecretKeySpec. key "AES")
             (GCMParameterSpec. (* TAGLEN 8) iv))
      (.updateAAD cipher (utf8 aad))
      {:iv iv :blob (.doFinal cipher plain)})
    (catch GeneralSecurityException err
      (fail (str "cannot seal: " (.getMessage err))))))

(defn- unseal
  "The plaintext, or a refusal. A GCM tag that fails to verify is the only
  evidence there is, and it cannot tell a wrong passphrase from a damaged
  file, so `what` names the attempt and the message admits both."
  ^bytes [^bytes key sealed ^String aad ^String what]
  (let [^bytes blob (:blob sealed)
        ^bytes iv (:iv sealed)]
    (when (or (< (alength blob) TAGLEN) (not= IVLEN (alength iv)))
      (fail (str what ": truncated")))

    ;; The WHOLE round-trip is guarded, not only the tag check: a nonce of
    ;; the wrong length makes `init` itself raise, and a damaged file
    ;; reaching a caller as a raw GeneralSecurityException is a refusal
    ;; nobody can act on.
    (try
      (let [cipher (Cipher/getInstance "AES/GCM/NoPadding")]
        (.init cipher Cipher/DECRYPT_MODE (SecretKeySpec. key "AES")
               (GCMParameterSpec. (* TAGLEN 8) iv))
        (.updateAAD cipher (utf8 aad))
        (.doFinal cipher blob))
      (catch Exception _ (fail what)))))

(defn- jsonof [^bytes plain what]
  (let [parsed (json/parse (String. plain StandardCharsets/UTF_8))]
    (if (map? parsed) parsed (fail (str "unreadable " what)))))

(defn- b64 [^bytes bytes]
  (.encodeToString (Base64/getEncoder) bytes))

(defn- unb64 ^bytes [text what]
  (when-not (string? text)
    (fail (str "missing " what)))
  (try
    (.decode (Base64/getDecoder) ^String text)
    (catch IllegalArgumentException _ (fail (str "missing " what)))))

;; --- the file --------------------------------------------------------

(defn- reader
  "A cursor, so that every length check is in one place: a truncated vault
  is refused rather than read as a short one."
  [^bytes bytes]
  (let [at (atom 0)]
    (letfn [(take! [^long len]
              (when (or (neg? len) (< (alength bytes) (+ @at len)))
                (fail "the vault file is truncated"))
              (let [out (Arrays/copyOfRange bytes (int @at) (int (+ @at len)))]
                (swap! at + len)
                out))
            (u8 [] (bit-and (aget ^bytes (take! 1) 0) 0xff))
            (u32 []
              ;; A length over Integer/MAX_VALUE cannot address an array,
              ;; and reading it as a negative int is what turned a damaged
              ;; file into a crash instead of a refusal.
              (let [value (bit-and (.getInt (ByteBuffer/wrap (take! 4))) 0xffffffff)]
                (when (< Integer/MAX_VALUE value)
                  (fail "the vault file is truncated"))
                value))]
      {:take take! :u8 u8 :u32 u32
       :small (fn [] (take! (u8)))
       :large (fn [] (take! (u32)))
       :magic (fn [] (String. ^bytes (take! 4) StandardCharsets/ISO_8859_1))
       :sealed (fn [] {:iv (take! (u8)) :blob (take! (u32))})
       :done? (fn [] (= @at (alength bytes)))})))

(defn- readfile [^bytes bytes]
  (let [read (reader bytes)
        u8 (:u8 read)
        u32 (:u32 read)
        small (:small read)
        sealed (:sealed read)]

    (when (not= MAGIC ((:magic read))) (fail "not a vault file"))

    (let [version (u8)]
      (when (not= FORMAT version) (fail (str "unsupported format version: " version))))

    (let [kdf (u8) cipher (u8)]
      (when (or (not= KDF-PBKDF2 kdf) (not= CIPHER-AESGCM cipher))
        (fail (str "unsupported kdf or cipher: " kdf "/" cipher))))
    (u8)

    (let [keys (vec (repeatedly (u32)
                                #(let [id (String. ^bytes (small) StandardCharsets/UTF_8)
                                       salt (small)
                                       iters (u32)]
                                   {:id id :salt salt :iters iters
                                    :ring (sealed) :meta (sealed)})))
          entries (vec (repeatedly (u32)
                                   #(let [id (small)]
                                      {:id id :name (sealed) :value (sealed)})))]
      (when-not ((:done? read)) (fail "the vault file has trailing bytes"))
      {:keys keys :entries entries})))

(defn- bytecompare
  "Unsigned, byte by byte, the way every other port sorts."
  [^bytes left ^bytes right]
  (let [len (min (alength left) (alength right))]
    (loop [index 0]
      (if (= index len)
        (compare (alength left) (alength right))
        (let [one (bit-and (aget left index) 0xff)
              two (bit-and (aget right index) 0xff)]
          (if (= one two) (recur (inc index)) (compare one two)))))))

(defn- writefile ^bytes [vault]
  (let [out (ByteArrayOutputStream.)]
    (letfn [(raw [^bytes bytes] (.write out bytes 0 (alength bytes)))
            (u8 [value] (.write out (int (bit-and value 0xff))))
            (u32 [value] (raw (.array (.putInt (ByteBuffer/allocate 4) (int value)))))
            (small [^bytes bytes] (u8 (alength bytes)) (raw bytes))
            (large [^bytes bytes] (u32 (alength bytes)) (raw bytes))
            (sealed [value] (small (:iv value)) (large (:blob value)))]

      (raw (.getBytes ^String MAGIC StandardCharsets/ISO_8859_1))
      (u8 FORMAT)
      (u8 KDF-PBKDF2)
      (u8 CIPHER-AESGCM)
      (u8 0)

      (u32 (count (:keys vault)))
      (doseq [key (:keys vault)]
        (small (utf8 (:id key)))
        (small (:salt key))
        (u32 (:iters key))
        (sealed (:ring key))
        (sealed (:meta key)))

      ;; SORTED BY ID, which is a blinded value: the file therefore records
      ;; nothing about the order secrets were written in.
      (let [entries (sort-by :id bytecompare (:entries vault))]
        (u32 (count entries))
        (doseq [entry entries]
          (small (:id entry))
          (sealed (:name entry))
          (sealed (:value entry))))

      (.toByteArray out))))

;; --- creating --------------------------------------------------------

(defn- newvault [keyid passphrase iterations]
  (let [root (randombytes KEYLEN)
        salt (randombytes SALTLEN)
        ring {"v" FORMAT "write" true "root" (b64 root)}
        meta {"v" FORMAT "master" true "write" true "grants" []}]
    {:keys [{:id keyid
             :salt salt
             :iters iterations
             :ring (seal (kek passphrase salt iterations)
                         (utf8 (json/stringify ring)) (str AAD-RING keyid))
             :meta (seal (hmac root LABEL-META)
                         (utf8 (json/stringify meta)) (str AAD-META keyid))}]
     :entries []}))

(defn- owneronly [^Path path]
  (try
    (Files/setPosixFilePermissions path (PosixFilePermissions/fromString "rw-------"))
    (catch Exception _
      ;; A filesystem with no POSIX permissions is not a reason to refuse a
      ;; write that otherwise succeeded.
      nil)))

(defn- putnew
  "Write a vault file that is not there yet, and REFUSE one that is.

  Straight to the target with CREATE_NEW rather than through a temporary
  and a rename. A rename REPLACES its destination, so two processes
  creating the same vault both succeeded and the second discarded the
  first one's secrets."
  [^String file vault]
  (let [path (Path/of file (into-array String []))]
    (try
      (Files/write path ^bytes (writefile vault)
                   (into-array StandardOpenOption
                               [StandardOpenOption/CREATE_NEW StandardOpenOption/WRITE]))
      (owneronly path)
      (catch FileAlreadyExistsException _
        (fail (str "vault file already exists: " file)))
      (catch java.io.IOException err
        (fail (str "cannot write " file ": " (.getMessage err)))))))

(defn- sameseal? [left right]
  (and (Arrays/equals ^bytes (:iv left) ^bytes (:iv right))
       (Arrays/equals ^bytes (:blob left) ^bytes (:blob right))))

;; --- the handle ------------------------------------------------------

(declare vaultbytes vaultload)

(defn openvault
  "Open a vault file as one key.

  The handle is lazy. Nothing is read, and no passphrase is stretched,
  until a call needs the file."
  [options]
  (let [opts (or options {})
        file (:file opts)
        passphrase (:passphrase opts)]
    (when-not (and (string? file) (not= "" file)) (fail "a vault needs a file"))
    (when-not (and (string? passphrase) (not= "" passphrase))
      (fail "a vault needs a passphrase"))

    {:file file
     :key (checkid (wantkey (:key opts)) "a vault needs a key id")
     :passphrase passphrase
     :iterations (or (:iterations opts) ITERATIONS)
     :create (true? (:create opts))
     ;; THE DERIVED KEYS LIVE IN AN ATOM. A handle that caches what it
     ;; derived and a handle that notices a revoked key are the same
     ;; handle, and a map is a value here.
     :opened (atom nil)}))

(defn createvault
  "Make a vault file and return a handle on its master key.

  Refuses a file that is already there: a vault is created once, and
  overwriting one discards every secret in it."
  [options]
  (let [opts (or options {})
        file (:file opts)
        passphrase (:passphrase opts)]
    (when-not (and (string? file) (not= "" file)) (fail "a vault needs a file"))
    (when-not (and (string? passphrase) (not= "" passphrase))
      (fail "a vault needs a passphrase"))

    (let [keyid (checkid (wantkey (:key opts)) "a vault needs a key id")]
      ;; No existence check first: the check and the write would be two
      ;; steps, and `putnew` refuses an existing file in ONE.
      (putnew file (newvault keyid passphrase (or (:iterations opts) ITERATIONS)))
      (openvault opts))))

(defn- vaultbytes ^bytes [vault]
  (let [^String file (:file vault)
        path (Path/of file (into-array String []))]
    (try
      (Files/readAllBytes path)
      (catch NoSuchFileException _
        ;; A vault is configured deliberately, with a key. Its absence is a
        ;; broken deployment and never "no secrets here": answering a miss
        ;; would send the chain on to a weaker store.
        (when-not (:create vault) (fail (str "no vault file: " file)))
        (putnew file (newvault (:key vault) (:passphrase vault) (:iterations vault)))
        (Files/readAllBytes path))
      (catch java.io.IOException err
        (fail (str "cannot read " file ": " (.getMessage err)))))))

(defn- vaultload [vault]
  (let [file (readfile (vaultbytes vault))
        keyid (:key vault)
        record (first (filter #(= keyid (:id %)) (:keys file)))]

    (when (nil? record)
      ;; REVOKED, or never there. Either way this handle is finished, and
      ;; dropping what it derived is what stops the next call answering
      ;; from memory.
      (reset! (:opened vault) nil)
      (fail (str "no such key: " keyid)))

    (let [held @(:opened vault)]
      ;; The file still holds this key, and holds the SAME ring: a key
      ;; revoked and re-granted under another passphrase is a different key
      ;; wearing the id, and re-deriving is what refuses it.
      (if (and held (sameseal? (:ring held) (:ring record)))
        [file held]
        (do
          (reset! (:opened vault) nil)
          (let [plain (unseal (kek (:passphrase vault) (:salt record) (:iters record))
                              (:ring record) (str AAD-RING keyid)
                              (str "wrong passphrase for key " keyid ", or a damaged vault"))
                ring (jsonof plain (str "key ring for " keyid))
                grants (reduce-kv (fn [out name key]
                                    (assoc out name (unb64 key "a granted key")))
                                  {} (or (get ring "grants") {}))
                root (get ring "root")
                opened {:info {"key" keyid
                               "master" (some? root)
                               "write" (or (some? root) (true? (get ring "write")))
                               "grants" (vec (sort (keys grants)))}
                        :root (when root (unb64 root "the root key"))
                        :grants grants
                        :ring (:ring record)}]
            (reset! (:opened vault) opened)
            [file opened]))))))

(defn- rootof ^bytes [opened what]
  (or (:root opened)
      (fail (str what " needs a master key, and " (get-in opened [:info "key"])
                 " is restricted"))))

(defn- keyfor
  "The key for one name, or nil when this key cannot reach it."
  ^bytes [opened name]
  (if-let [root (:root opened)]
    (secretkey root name)
    (get (:grants opened) name)))

(defn- findentry [file ^bytes key]
  (when key
    (let [id (entryid key)]
      (first (filter #(Arrays/equals ^bytes (:id %) id) (:entries file))))))

(defn- metaof [opened record]
  (let [root (rootof opened "reading key metadata")
        what (str "metadata for key " (:id record))]
    (try
      (jsonof (unseal (hmac root LABEL-META) (:meta record)
                      (str AAD-META (:id record)) what)
              what)
      (catch clojure.lang.ExceptionInfo _
        ;; A record written under a root key this one has replaced. The key
        ;; is still in the file and still opens with its own passphrase, so
        ;; it is reported rather than hidden - with what it can do unknown.
        nil))))

(defn- sealkey [^bytes root id phrase iters ring meta]
  (let [salt (randombytes SALTLEN)]
    {:id id
     :salt salt
     :iters iters
     :ring (seal (kek phrase salt iters) (utf8 (json/stringify ring)) (str AAD-RING id))
     :meta (seal (hmac root LABEL-META) (utf8 (json/stringify meta)) (str AAD-META id))}))

(defn- writevault
  "Read, change, and REPLACE - never edit in place.

  THE TEMPORARY IS RANDOM AND EXCLUSIVE. `<vault>.<pid>.tmp` is a name
  anyone can predict, so anyone who can write the vault's directory could
  put a symlink there and have the next save truncate whatever it pointed
  at."
  [vault file]
  (let [^String target (:file vault)
        suffix (apply str (map #(format "%02x" (bit-and % 0xff)) (randombytes 8)))
        temp (Path/of (str target "." suffix ".tmp") (into-array String []))]
    (try
      (Files/write temp ^bytes (writefile file)
                   (into-array StandardOpenOption
                               [StandardOpenOption/CREATE_NEW StandardOpenOption/WRITE]))
      (owneronly temp)
      (Files/move temp (Path/of target (into-array String []))
                  (into-array StandardCopyOption [StandardCopyOption/REPLACE_EXISTING]))
      (catch java.io.IOException err
        (try (Files/deleteIfExists temp) (catch Exception _ nil))
        (fail (str "cannot write " target ": " (.getMessage err)))))
    nil))

(defn vaultfile
  "The file this handle reads."
  [vault]
  (:file vault))

(defn vaultkey
  "The key id this handle opens with."
  [vault]
  (:key vault))

(defn vaultopen
  "Derive the key and read the file NOW rather than at first use.

  A COPY, so that what a caller is handed cannot become what this vault
  believes: a map is a value here."
  [vault]
  (:info (second (vaultload vault))))

(defn vaultclose
  "Forget the derived keys. The next call opens again."
  [vault]
  (reset! (:opened vault) nil)
  nil)

(defn vaultlist
  "The names this key can read, sorted."
  [vault]
  (let [[file opened] (vaultload vault)]
    (if-let [root (:root opened)]
      (let [namekey (hmac root LABEL-NAMES)]
        (vec (sort (map #(String. ^bytes (unseal namekey (:name %) AAD-NAME
                                                 "a secret name is damaged")
                                  StandardCharsets/UTF_8)
                        (:entries file)))))
      ;; A restricted key has no name key, so it reports the grants it can
      ;; actually find: the vault never tells it what else is in there.
      (vec (sort (filter #(some? (findentry file (get (:grants opened) %)))
                         (get-in opened [:info "grants"])))))))

(defn vaultget
  "The value, or nil when the vault does not hold that name or this key was
  not granted it."
  [vault name]
  (core/checkname name)
  (let [[file opened] (vaultload vault)
        key (keyfor opened name)]
    ;; OUTSIDE THE GRANT IS A MISS, deliberately. The vault answers as the
    ;; key that opened it, so a name this key cannot read is a name this
    ;; store does not hold for this caller.
    (when key
      (when-let [entry (findentry file key)]
        (String. ^bytes (unseal key (:value entry) (str AAD-SECRET name)
                                (str "the value of " name " is damaged"))
                 StandardCharsets/UTF_8)))))

(defn vaulthas?
  "Does this key hold a value for `name`?"
  [vault name]
  (some? (vaultget vault name)))

(defn vaultset
  "Write a value. A master writes any name; a restricted key holding
  `write` overwrites the names it was granted, and creates none."
  [vault name value]
  ;; Every write on this file, from any handle in this process,
  ;; serializes here; see lockfor.
  (locking (lockfor (:file vault))
    (core/checkname name)
    (when-not (string? value) (fail (str "a secret value must be text: " name)))

    (let [[file opened] (vaultload vault)]
      (when-not (get-in opened [:info "write"])
        (fail (str "key " (get-in opened [:info "key"]) " is read-only")))

      (let [key (or (keyfor opened name)
                    (fail (str "key " (get-in opened [:info "key"])
                               " was not granted " name)))
            sealedvalue (seal key (utf8 value) (str AAD-SECRET name))
            id (entryid key)
            found (findentry file key)
            entries (if found
                      (mapv #(if (Arrays/equals ^bytes (:id %) id)
                               (assoc % :value sealedvalue) %)
                            (:entries file))
                      ;; A NEW NAME NEEDS THE NAME KEY, which only a master
                      ;; holds. So a restricted key with `write` updates what
                      ;; it was granted and cannot grow the vault.
                      (let [root (rootof opened (str "creating the secret " name))]
                        (conj (:entries file)
                              {:id id
                               :name (seal (hmac root LABEL-NAMES) (utf8 name) AAD-NAME)
                               :value sealedvalue})))]
        (writevault vault (assoc file :entries entries))))))

(defn vaultremove
  "Drop a name. Master only."
  [vault name]
  ;; Every write on this file, from any handle in this process,
  ;; serializes here; see lockfor.
  (locking (lockfor (:file vault))
    (core/checkname name)
    (let [[file opened] (vaultload vault)
          root (rootof opened "removing a secret")
          wanted (entryid (secretkey root name))]
      (when-not (some #(Arrays/equals ^bytes (:id %) wanted) (:entries file))
        (fail (str "no such secret: " name)))
      (writevault vault
                  (assoc file :entries
                         (vec (remove #(Arrays/equals ^bytes (:id %) wanted)
                                      (:entries file))))))))

(defn vaultkeys
  "Every key in the file, with what it may do. Master only."
  [vault]
  (let [[file opened] (vaultload vault)]
    (rootof opened "listing the keys")
    (mapv (fn [record]
            (if-let [meta (metaof opened record)]
              {"key" (:id record)
               "master" (true? (get meta "master"))
               "write" (true? (get meta "write"))
               "grants" (vec (sort (or (get meta "grants") [])))}
              {"key" (:id record) "master" false "write" false "grants" []}))
          (:keys file))))

(defn vaultgrant
  "Mint a restricted key. Master only."
  [vault spec]
  ;; Every write on this file, from any handle in this process,
  ;; serializes here; see lockfor.
  (locking (lockfor (:file vault))
    (let [[file opened] (vaultload vault)
          root (rootof opened "granting a key")
          want (or spec {})
          id (checkid (:key want) "a grant needs a key id")
          phrase (:passphrase want)]

      (when-not (and (string? phrase) (not= "" phrase)) (fail "a grant needs a passphrase"))
      (when (some #(= id (:id %)) (:keys file)) (fail (str "key already exists: " id)))

      (let [names (vec (sort (or (:names want) [])))
            grants (reduce (fn [out name]
                             (core/checkname name)
                             (assoc out name (b64 (secretkey root name))))
                           {} names)
            write (true? (:write want))
            record (sealkey root id phrase (or (:iterations want) (:iterations vault))
                            {"v" FORMAT "write" write "grants" grants}
                            {"v" FORMAT "master" false "write" write "grants" names})]
        (writevault vault (assoc file :keys (conj (:keys file) record)))))))

(defn vaultrevoke
  "Drop a key. Master only.

  Anyone who already copied the file keeps whatever that key could read, so
  revoking bars future reads of the LIVE file and `vaultrotate` is what
  takes a secret back."
  [vault key]
  ;; Every write on this file, from any handle in this process,
  ;; serializes here; see lockfor.
  (locking (lockfor (:file vault))
    (let [[file opened] (vaultload vault)]
      (rootof opened "revoking a key")
      (when (= key (get-in opened [:info "key"]))
        (fail (str "a key cannot revoke itself: " key)))
      (when-not (some #(= key (:id %)) (:keys file)) (fail (str "no such key: " key)))
      (writevault vault (assoc file :keys (vec (remove #(= key (:id %)) (:keys file))))))))

(defn vaultrotate
  "A new root key, every value re-encrypted under it, and EVERY OTHER KEY
  DROPPED. Master only.

  The other keys go because they must: their rings are sealed under
  passphrases this process does not have. Re-grant afterwards."
  [vault]
  ;; Every write on this file, from any handle in this process,
  ;; serializes here; see lockfor.
  (locking (lockfor (:file vault))
    (let [[file opened] (vaultload vault)]
      (rootof opened "rotating the vault")

      ;; Read everything out under the old root before anything changes: once
      ;; the root is replaced the old derived keys are unreachable.
      (let [plain (mapv (fn [name] [name (vaultget vault name)]) (vaultlist vault))
            root (randombytes KEYLEN)
            namekey (hmac root LABEL-NAMES)
            entries (mapv (fn [[name value]]
                            (let [key (secretkey root name)]
                              {:id (entryid key)
                               :name (seal namekey (utf8 name) AAD-NAME)
                               :value (seal key (utf8 value) (str AAD-SECRET name))}))
                          plain)
            iters (or (:iters (first (filter #(= (:key vault) (:id %)) (:keys file))))
                      (:iterations vault))
            record (sealkey root (:key vault) (:passphrase vault) iters
                            {"v" FORMAT "write" true "root" (b64 root)}
                            {"v" FORMAT "master" true "write" true "grants" []})]

        ;; SAVE FIRST, adopt second. A handle holding the new root over a file
        ;; that still holds the old one reads nothing and says the vault is
        ;; damaged.
        (writevault vault {:keys [record] :entries entries})

        (reset! (:opened vault)
                {:info {"key" (:key vault) "master" true "write" true "grants" []}
                 :root root
                 :grants {}
                 :ring (:ring record)})
        nil))))

;; --- the provider ----------------------------------------------------

(defrecord MiniVaultProvider [vault]
  provider/Provider

  (lookup [_ name] (vaultget vault name))

  (describe [_] (str "minivault:" (:file vault))))

(defn providerof
  "Read a vault as one store in a chain.

  The provider is the READ half and nothing more: a chain resolves secrets,
  and writing one is a deliberate act with an API of its own."
  [vault]
  (->MiniVaultProvider vault))

(defn minivaultprovider
  "A vault provider from options, for a chain built by hand."
  [options]
  (providerof (openvault options)))

(defn- vaultoptions [spec]
  {:file (or (core/notempty (:file spec)) "")
   :key (core/notempty (:vaultkey spec))
   :passphrase (or (core/notempty (:passphrase spec)) "")
   :iterations (:iterations spec)
   :create (true? (:create spec))})

(def minivault
  "The `minivault` provider kind, as a voxgig/plugin definition.

  Written out rather than built by `providerplugin`, because this
  definition publishes TWO exports: `provider`, the read half every kind
  publishes, and `vault`, the programmatic API."
  {"name" "minivault"
   "define" (fn [inst]
              (let [built (try
                            ;; `openvault` refuses bad configuration HERE,
                            ;; so a mistyped chain fails at construction.
                            ;; Reaching the FILE is not configuration: the
                            ;; handle is lazy.
                            (openvault (vaultoptions (host/inst-options inst)))
                            (catch clojure.lang.ExceptionInfo err
                              (if (core/sekretoerror? err)
                                (plugintypes/fail providers/ERROR-CODE (ex-message err)
                                                  {"ref" (host/inst-ref inst)
                                                   "cause" (ex-message err)})
                                (throw err))))]
                (host/export! inst providers/PROVIDER-EXPORT (providerof built))
                (host/export! inst VAULT-EXPORT built)))})

(defn vaultof
  "The vault behind a store in a chain, as its programmatic API.

  With no store named, the unqualified alias answers: one vault in the
  chain resolves whatever it is called, and two raise rather than picking
  one."
  ([secrets] (vaultof secrets nil))
  ([secrets store]
   (let [h (:host secrets)]
     (if (nil? store)
       (or (host/exports h (str "minivault/" VAULT-EXPORT))
           (fail "no minivault store in this chain"))
       ;; A NAMED STORE MUST EXIST, and the alias must not stand in for it.
       ;; `host.exports` falls back to the alias when the exact ref misses,
       ;; so asking for `minivault` in a chain whose only vault is named
       ;; `app` used to hand back the `app` vault - and then write to it.
       (let [ref (if (= "minivault" store) "minivault" (str "minivault$" store))]
         (when (nil? (host/instance h ref))
           (fail (str "no minivault store named " store " in this chain")))
         (host/exports h (str ref "/" VAULT-EXPORT)))))))
