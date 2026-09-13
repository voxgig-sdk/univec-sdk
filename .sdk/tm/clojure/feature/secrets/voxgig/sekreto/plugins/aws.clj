;; VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (clojure/plugins/voxgig/sekreto/plugins/aws.clj)
;; Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
;; License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
;; The two AWS stores, as voxgig/plugin definitions - and the only two
;; kinds that sign a request.
;;
;; ONE PLUGIN, TWO KINDS: Secrets Manager and Parameter Store share a
;; signer, so they ship together and `sigv4` comes with them. That is what
;; keeps the core of every port free of a hash function
;; (docs/design/plugin-providers.md).
;;
;; A port of typescript/plugins/aws.ts, which is canonical.

(ns voxgig.sekreto.plugins.aws
  (:require [clojure.string :as string]
            [voxgig.sekreto.core :as core]
            [voxgig.sekreto.addr :refer [checkaddr]]
            [voxgig.sekreto.json :as json]
            [voxgig.sekreto.provider :as provider]
            [voxgig.sekreto.providers :as providers]
            [voxgig.sekreto.plugins.httpjson :as http]
            [voxgig.sekreto.plugins.sigv4 :as sigv4])
  (:import [java.nio.charset StandardCharsets]
           [java.time Instant ZoneOffset]
           [java.time.format DateTimeFormatter]
           [java.util Base64]))

(defn awsnow
  "The `YYYYMMDDTHHMMSSZ` timestamp SigV4 wants, for now."
  []
  (.format (.withZone (DateTimeFormatter/ofPattern "yyyyMMdd'T'HHmmss'Z'") ZoneOffset/UTC)
           (Instant/now)))

(defn awsauth
  "Region and credentials, from config first and the standard AWS_*
  environment variables second - those are AWS's own convention, and a pod
  or CI job that has them set should just work. Missing either is an error:
  an AWS store with no credentials could not answer."
  [{:keys [region keyid secret session]}]
  (let [useregion (http/firstof region (core/getenv "AWS_REGION") (core/getenv "AWS_DEFAULT_REGION"))
        usekeyid (http/firstof keyid (core/getenv "AWS_ACCESS_KEY_ID"))
        usesecret (http/firstof secret (core/getenv "AWS_SECRET_ACCESS_KEY"))
        usesession (http/firstof session (core/getenv "AWS_SESSION_TOKEN"))]

    (when (= "" useregion)
      (throw (core/sekretoerror "sekreto: aws: no region (set region or AWS_REGION)")))

    (when (or (= "" usekeyid) (= "" usesecret))
      (throw (core/sekretoerror
              (str "sekreto: aws: no credentials"
                   " (set keyid/secret or AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY)"))))

    {:region useregion :keyid usekeyid :secret usesecret :session (core/notempty usesession)}))

(defn awscall
  "One signed call to an AWS JSON-1.1 API."
  [config service target payload]
  (let [auth (awsauth config)
        ;; The China partition lives under its own suffix; every other
        ;; commercial region is plain amazonaws.com.
        suffix (if (string/starts-with? (:region auth) "cn-") ".amazonaws.com.cn" ".amazonaws.com")
        useaddr (http/firstof (:addr config) (str "https://" service "." (:region auth) suffix))
        _ (checkaddr useaddr)
        url (str (http/trimslash useaddr) "/")
        extras (json/omap [["content-type" "application/x-amz-json-1.1"] ["x-amz-target" target]])
        signed (sigv4/sigv4 {:method "POST"
                             :url url
                             :service service
                             :region (:region auth)
                             :keyid (:keyid auth)
                             :secret (:secret auth)
                             :datetime (awsnow)
                             :headers extras
                             :body payload
                             :session (:session auth)})]
    (http/fetchjson "POST" url (merge extras signed) payload)))

(defn awsmiss?
  "Does this AWS error body name one of the not-found types? Those are a
  miss; every other failure is a store that could not answer."
  [body & types]
  (let [errtype (json/asstr (json/dig body "__type"))]
    (boolean (and errtype (some (fn [want] (string/includes? errtype want)) types)))))

(defrecord Awssecrets [region keyid secret session addr]
  provider/Provider

  ;; AWS Secrets Manager.
  ;;
  ;; `api.token` reads the secret named `api` (the vaultref path, so
  ;; `db.pass.main` reads `db/pass`) and takes the `token` field of its JSON
  ;; SecretString - the AWS idiom of one JSON map per secret. A SecretString
  ;; that is not JSON is the value itself, under the conventional field
  ;; `value`. Requests are SigV4-signed in-tree; see sigv4.clj.
  (lookup [this name]
    (let [ref (core/vaultref name)
          res (awscall this "secretsmanager" "secretsmanager.GetSecretValue"
                       (json/stringify (json/omap [["SecretId" (:path ref)]])))]

      (cond
        (and (= 400 (:status res)) (awsmiss? (:body res) "ResourceNotFoundException")) nil

        (not= 200 (:status res))
        (throw (core/sekretoerror (str "sekreto: aws secretsmanager error: " (:status res))))

        :else
        (if-let [text (json/asstr (json/dig (:body res) "SecretString"))]
          (let [fields (json/parse text)]
            (if (map? fields)
              (json/astext (json/dig fields (:field ref)))
              ;; A plain-string secret is the whole value; it has no named
              ;; fields.
              (when (= "value" (:field ref)) text)))

          ;; A binary secret has no fields to address; only the conventional
          ;; `value` field can mean "the bytes themselves".
          (let [bin (json/asstr (json/dig (:body res) "SecretBinary"))]
            (when (and bin (= "value" (:field ref)))
              (try
                (String. (.decode (Base64/getDecoder) ^String bin) StandardCharsets/UTF_8)
                ;; A store that answered incoherently is an error, and the
                ;; decoder's own complaint is not one of this library's.
                (catch IllegalArgumentException _
                  (throw (core/sekretoerror
                          "sekreto: aws secretsmanager: undecodable secret"))))))))))

  ;; Config only, never the environment: `describe` feeds the spec's sources
  ;; group, which must answer the same everywhere.
  (describe [_] (str "awssecrets:" (or region ""))))

(defrecord Awsparams [region keyid secret session addr prefix]
  provider/Provider

  ;; AWS SSM Parameter Store.
  ;;
  ;; `db.pass.main` reads the parameter `/db/pass/main` (under an optional
  ;; prefix path), decrypted. Parameter Store carries flat strings, so there
  ;; is no field indirection.
  (lookup [this name]
    (let [payload (json/omap [["Name" (core/awsparam name prefix)] ["WithDecryption" true]])
          res (awscall this "ssm" "AmazonSSM.GetParameter" (json/stringify payload))]

      (cond
        (and (= 400 (:status res)) (awsmiss? (:body res) "ParameterNotFound")) nil

        (not= 200 (:status res))
        (throw (core/sekretoerror (str "sekreto: aws ssm error: " (:status res))))

        :else (json/astext (json/dig (:body res) "Parameter" "Value")))))

  (describe [_] (str "awsparams:" (or region "") (or prefix ""))))

(def awssecrets
  "The `awssecrets` provider kind: AWS Secrets Manager."
  (providers/providerplugin
   "awssecrets"
   (fn [{:keys [region keyid secret session addr]}]
     (->Awssecrets region keyid secret session addr))))

(def awsparams
  "The `awsparams` provider kind: AWS SSM Parameter Store."
  (providers/providerplugin
   "awsparams"
   (fn [{:keys [region keyid secret session addr prefix]}]
     (->Awsparams region keyid secret session addr prefix))))
