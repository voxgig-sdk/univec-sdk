;; VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (clojure/src/voxgig/sekreto/chain.clj)
;; Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
;; The chain: a Sekreto is an ordered list of providers on a voxgig/plugin
;; host. `get` asks each in turn and returns the first hit, so an app can be
;; configured from environment variables in development and a vault in
;; production without changing a line of its own code.
;;
;; THIS NAMESPACE REQUIRES NO PLUGIN, IN ANY FORM. The four built-in kinds
;; - env, memory, dotenv, file - read at most a local file; every other kind
;; is a voxgig/plugin definition under `plugins/`, and a chain may name one
;; only if the calling project handed it in through `:plugins`. That is what
;; keeps an SDK whose chain is `[dotenv env]` from carrying AWS request
;; signing and seven HTTP vault clients. See
;; docs/design/plugin-providers.md.
;;
;; What is plugin's and what is sekreto's:
;;
;;   plugin owns  the catalog, the instances, name+tag addressing, the
;;                lifecycle, and the options each instance was declared
;;                with.
;;   sekreto owns the walk - reading each instance's exported provider off
;;                the host and asking them in order.
;;
;; A port of typescript/src/Sekreto.ts, which is canonical.

(ns voxgig.sekreto.chain
  (:refer-clojure :exclude [get])
  (:require [clojure.string :as string]
            [voxgig.sekreto.core :as core]
            [voxgig.sekreto.json :as json]
            [voxgig.sekreto.provider :as provider]
            [voxgig.sekreto.providers :as providers]
            [voxgig.plugin :as plugin]
            [voxgig.plugin.catalog :as catalog]
            [voxgig.plugin.host :as host]))

(defn storename
  "The store name a LIVE provider answers to.

  `describe` opens with the provider's kind - `hashicorp:...`,
  `dotenv:...`, plain `env` - so the kind is the natural default, and a
  custom provider gets a sensible name without implementing anything extra.
  A spec'd provider's store is its `:name` or its `:kind`, decided before
  the provider exists."
  [prov]
  (apply str (take-while (fn [ch] (not= \: ch)) (provider/describe prov))))

(defn- definition
  "A plugin entry, checked to be a definition before the catalog sees it.

  A definition is a map; a namespace and a symbol naming one are the two
  ways to hand over the container instead of the thing inside it, and both
  are refused here rather than deep inside voxgig/plugin with a message
  about a definition name."
  [plugin]
  (cond
    (map? plugin) plugin

    (or (instance? clojure.lang.Namespace plugin) (symbol? plugin))
    (let [named (str (if (instance? clojure.lang.Namespace plugin) (ns-name plugin) plugin))]
      (throw (core/sekretoerror
              (str "sekreto: not a plugin definition: the namespace " named
                   " - a plugin is a definition in it, such as "
                   named "/" (last (string/split named #"\."))
                   ", or voxgig.sekreto.plugins/ALL for every one"))))

    :else
    (throw (core/sekretoerror (str "sekreto: not a plugin definition: " (pr-str plugin))))))

(defn- unknownkind
  "The message for a kind the catalog does not hold.

  A kind sekreto has never heard of is a typo; a kind that exists as a
  plugin but was not passed in is the split working as designed and telling
  you what to pass. Collapsing the two was the first thing that made the
  split confusing to use."
  [kind cat]
  (str "sekreto: unknown provider kind: " (str kind)
       " (available: " (string/join ", " (catalog/definition-names cat)) ")"
       (when (some (fn [known] (= known kind)) (:plugin providers/KINDS))
         (str " - " kind " is a sekreto plugin, not built in:"
              " pass it in the plugins option"))))

(defn- unwrap
  "A sekreto error that crossed the plugin boundary comes back out as
  itself, byte for byte. Anything else is not sekreto's to rewrite."
  [err]
  (let [data (ex-data err)
        cause (clojure.core/get (:details data) "cause")]
    (if (and (= providers/ERROR-CODE (:code data)) (string? cause))
      (core/sekretoerror cause)
      err)))

(defrecord Sekreto [host catalog entries docache cache seen])

(defn- declareone
  "One chain entry, as a plugin instance.

  The instance is `kind` for a store named after its kind and `kind$store`
  otherwise - `hashicorp$prod` - so `host/list` reads like the chain. A
  store name that is already taken gets a numbered tag from the host
  instead, because two providers MAY share a store name (a directed read
  walks both) and an instance ref may not."
  [secrets spec]
  (let [cat (:catalog secrets)
        h (:host secrets)
        kind (when (map? spec) (:kind spec))]

    (when (or (nil? kind) (not (catalog/has-definition? cat kind)))
      (throw (core/sekretoerror (unknownkind kind cat))))

    (let [store (or (core/notempty (:name spec)) kind)]

      (when-not (plugin/check-tag store)
        (throw (core/sekretoerror (str "sekreto: invalid store name: " store))))

      (let [want (if (= store kind) kind (plugin/format-ref kind store))
            taken (some? (host/instance h want))

            ref (try
                  ;; `load` runs the definition's `define`, which builds the
                  ;; provider from the spec; `activate` takes the instance
                  ;; live. Nothing is contacted by either: a provider opens
                  ;; nothing until its first lookup.
                  (let [entry (if taken
                                (host/load h kind {"tag" "?" "options" spec})
                                (host/load h want {"options" spec}))
                        rf (entry "ref")]
                    (host/activate h rf)
                    rf)
                  (catch Exception err (throw (unwrap err))))

            built (host/exports h (str ref "/" providers/PROVIDER-EXPORT))]

        ;; A definition that exported no provider is not a provider kind.
        ;; Left alone it would answer every lookup with a nil pointer, one
        ;; layer further down and with nothing naming the plugin at fault.
        (when-not (satisfies? provider/Provider built)
          (throw (core/sekretoerror
                  (str "sekreto: not a provider plugin: " kind
                       " - a provider kind is made by providerplugin"))))

        {:store store :ref ref :provider built}))))

(defn make
  "A Sekreto from a chain of providers.

  Each entry is a declarative spec - a map whose `:kind` picks the provider
  kind and whose other keys are that kind's own - or a live provider,
  anything satisfying the `Provider` protocol.

  `:plugins` is the provider kinds beyond the four built-ins that the chain
  may name, as voxgig/plugin definitions. Static and explicit: the calling
  project requires the plugins it needs and passes them here, and a kind it
  did not pass is unknown to this Sekreto. `:cache` turns the read cache
  off, which the spec's chain groups do so that each entry starts clean."
  ([entries] (make entries nil))
  ([entries {:keys [plugins cache] :or {cache true}}]
   ;; Built-ins first, then the plugins, into one catalog: a plugin that
   ;; names a built-in kind replaces it, which is how a host substitutes an
   ;; implementation and never an accident, because the four names are
   ;; documented.
   (let [cat (plugin/make-catalog (into (vec providers/BUILTINS)
                                        (map definition (or plugins []))))
         secrets (->Sekreto
                  (plugin/make-host {"catalog" cat})
                  cat
                  (atom [])
                  (not (false? cache))
                  ;; A vector, not a map: the store a value came from stays
                  ;; attached, and redaction order does not vary between
                  ;; runs.
                  (atom [])
                  ;; Every value ever resolved, for `redactall`. Kept
                  ;; independently of the read cache so that redaction still
                  ;; works when the cache is off - otherwise an uncached
                  ;; Sekreto would silently disable redaction and leak
                  ;; secrets to logs.
                  (atom []))]

     (reset! (:entries secrets)
             (mapv (fn [entry]
                     ;; A live provider is backed by no instance; a spec'd
                     ;; one is an instance of its kind on the host.
                     (if (satisfies? provider/Provider entry)
                       {:store (storename entry) :ref "" :provider entry}
                       (declareone secrets entry)))
                   (or entries [])))

     secrets)))

(defn- resolvechain [secrets store name entries]
  (core/checkname name)

  (let [hit (when (:docache secrets)
              (some (fn [entry] (when (and (= store (:store entry)) (= name (:name entry))) entry))
                    @(:cache secrets)))]
    (if (some? hit)
      (:value hit)
      (let [found (some (fn [entry] (provider/lookup (:provider entry) name)) entries)]
        (when (some? found)
          (when (:docache secrets)
            (swap! (:cache secrets) conj {:store store :name name :value found}))
          (swap! (:seen secrets) conj found))
        found))))

(defn tryget
  "The secret, or nil if no provider has it. Named `tryget` because `try`
  is a Clojure special form."
  [secrets name]
  (resolvechain secrets "" name @(:entries secrets)))

(defn get
  "The secret, or a sekreto error if no provider has it."
  [secrets name]
  (let [found (tryget secrets name)]
    (when (nil? found)
      (throw (core/sekretoerror (str "sekreto: unknown secret: " name))))
    found))

(defn tryfrom
  "The secret from one named store, or nil if that store does not have it.

  Naming a store that is not in the chain is an error, not a miss: `tryget`
  already means \"this store may not have it\", so it cannot also mean
  \"this store may not exist\" without hiding a typo."
  [secrets store name]
  (let [matching (filterv (fn [entry] (= store (:store entry))) @(:entries secrets))]
    (when (empty? matching)
      (throw (core/sekretoerror (str "sekreto: unknown store: " store))))
    (resolvechain secrets store name matching)))

(defn getfrom
  "The secret from one named store, or a sekreto error if that store does
  not have it."
  [secrets store name]
  (let [found (tryfrom secrets store name)]
    (when (nil? found)
      (throw (core/sekretoerror (str "sekreto: unknown secret: " store ":" name))))
    found))

(defn has
  "Does any provider have this secret?"
  [secrets name]
  (some? (tryget secrets name)))

(defn hasin
  "Does this named store have this secret?"
  [secrets store name]
  (some? (tryfrom secrets store name)))

(defn all
  "Every named secret at once, in the order asked. Missing ones are an error."
  [secrets names]
  (json/omap (map (fn [name] [name (get secrets name)]) names)))

(defn sources
  "A description of each provider, in resolution order."
  [secrets]
  (mapv (fn [entry] (provider/describe (:provider entry))) @(:entries secrets)))

(defn stores
  "The name of each store that can be named by `getfrom`, in resolution
  order and without repeats."
  [secrets]
  (vec (distinct (map :store @(:entries secrets)))))

(defn redactall
  "Replace every value THIS Sekreto has resolved with `[redacted]`.

  Named `redactall` - as in the Perl port - because `redact` is already the
  pure two-argument function in `voxgig.sekreto.core`, and both take two
  arguments here.

  Works whether or not caching is enabled: the redaction list is kept
  independently of the read cache."
  [secrets text]
  (core/redact text @(:seen secrets)))

(defn refresh
  "Drop cached values, so the next `get` asks the providers again."
  [secrets]
  (reset! (:cache secrets) [])
  nil)

(defn close
  "Tear the chain down: every plugin instance is deactivated and unloaded,
  in reverse, releasing whatever a provider acquired at activation.
  Afterwards there is nothing to read from - `get` reports every secret
  unknown - and the cache is dropped, though `redactall` still knows every
  value that was ever resolved."
  [secrets]
  (host/close (:host secrets))
  (reset! (:entries secrets) [])
  (reset! (:cache secrets) [])
  nil)
