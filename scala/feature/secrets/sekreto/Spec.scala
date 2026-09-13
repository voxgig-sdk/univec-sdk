// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (scala/src/Spec.scala)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The declarative form of a provider, and the credentials it may carry.
//
// `ProviderSpec` is what a config file, the shared spec and an app's own
// chain description all look like: `kind` picks the provider and
// everything else is that kind's own. A plugin instance reads it back out
// of `inst.options` (see Support.scala).
//
// A port of typescript/src/provider/support.ts, which is canonical.

package com.voxgig.sekreto

/** Logging in to a vault instead of being handed a token. `method` is
  * `kubernetes` or `approle`; `mount` defaults to the method name.
  */
case class AuthSpec(
    method: String,
    mount: Option[String] = None,
    /** kubernetes: the Vault role to log in as. */
    role: Option[String] = None,
    /** kubernetes: the service-account JWT itself (tests). */
    jwt: Option[String] = None,
    /** kubernetes: where the JWT lives; the conventional pod path by default. */
    jwtfile: Option[String] = None,
    /** approle: the role and secret ids. */
    roleid: Option[String] = None,
    secretid: Option[String] = None,
):

  /** Printed without its credentials.
    *
    * A `case class` generates a `toString` that prints every field, so
    * `logger.error(s"bad chain: $specs")` - which is what someone writes
    * when a chain will not build - would put the service-account JWT and the
    * AppRole secret id in the log. Fields that hold a credential report
    * whether they are set, never what they are.
    */
  override def toString: String =
    s"AuthSpec(method=$method, mount=$mount, role=$role, jwtfile=$jwtfile, " +
      s"roleid=$roleid, jwt=${setornot(jwt)}, secretid=${setornot(secretid)})"

/** What a credential field reports about itself. */
private[sekreto] def setornot(value: Option[String]): String =
  if value.exists(_.nonEmpty) then "[set]" else "[unset]"

/** The declarative form of a provider, as used in config and in the shared
  * spec. `kind` picks the provider; everything else is that kind's own.
  */
case class ProviderSpec(
    kind: String,
    /** The store name `Sekreto.getfrom` addresses. Defaults to `kind`. */
    name: Option[String] = None,
    prefix: Option[String] = None,
    /** dotenv: the file to read. secretspec: the declaration to read. */
    file: Option[String] = None,
    /** memory: literal values, keyed like environment variables. */
    values: Option[Map[String, String]] = None,
    /** file: the directory of one-secret-per-file entries. */
    dir: Option[String] = None,
    /** hashicorp / boru (wire) / gcp / 1password / doppler / infisical: the base URL. */
    addr: Option[String] = None,
    /** hashicorp / boru (wire) / gcp / azure / 1password / doppler / infisical: the token. */
    token: Option[String] = None,
    /** hashicorp / boru (wire): the KV mount (default `secret`). */
    mount: Option[String] = None,
    /** hashicorp: KV engine version, 1 or 2 (default 2). */
    kv: Option[Int] = None,
    /** hashicorp: Vault Enterprise namespace (X-Vault-Namespace). */
    vaultnamespace: Option[String] = None,
    /** hashicorp: log in for a token instead of being handed one. */
    auth: Option[AuthSpec] = None,
    /** boru / secretspec: the executable to run (default: the kind's own name). */
    command: Option[String] = None,
    /** secretspec: the profile to read (`--profile`). */
    profile: Option[String] = None,
    /** secretspec: which of ITS backends to read from (`--provider`), e.g.
      * `keyring` or `dotenv://.env`. Named `backend` here because `provider`
      * already means a sekreto provider.
      */
    backend: Option[String] = None,
    /** secretspec: the audit reason recorded for the read (`--reason`).
      * SecretSpec refuses to read without one.
      */
    reason: Option[String] = None,
    /** boru: the namespace qualifying the alias. */
    namespace: Option[String] = None,
    /** boru: the vault home, passed as BORU_HOME. */
    home: Option[String] = None,
    /** aws: region and credentials; the standard AWS_* variables fill the rest. */
    region: Option[String] = None,
    keyid: Option[String] = None,
    secret: Option[String] = None,
    session: Option[String] = None,
    /** gcp / doppler / infisical: the project, however that store names it. */
    project: Option[String] = None,
    /** azure: the Key Vault name or full URL. 1password: the vault name or id. */
    vault: Option[String] = None,
    /** azure: client-credential login. infisical: universal-auth login. */
    tenant: Option[String] = None,
    clientid: Option[String] = None,
    clientsecret: Option[String] = None,
    /** azure: where to log in / where IMDS answers. gcp: the metadata server. */
    loginaddr: Option[String] = None,
    imdsaddr: Option[String] = None,
    metadataaddr: Option[String] = None,
    /** azure: the Key Vault API version (default 7.4). */
    apiversion: Option[String] = None,
    /** doppler: the config slug (with `project`). */
    config: Option[String] = None,
    /** infisical: the environment slug and secret path. */
    environment: Option[String] = None,
    path: Option[String] = None,
):

  /** Printed without its credentials. See AuthSpec.toString: the generated
    * one would put the Vault token, the AWS secret access key and the Azure
    * client secret into whatever formatted it.
    */
  override def toString: String =
    s"ProviderSpec(kind=$kind, name=$name, addr=$addr, token=${setornot(token)}, " +
      s"secret=${setornot(secret)}, clientsecret=${setornot(clientsecret)}, auth=$auth)"
