// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (kotlin/src/Spec.kt)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The declarative form of a provider, and the credentials it may carry.
//
// `ProviderSpec` is what a config file, the shared spec and an app's own
// chain description all look like: `kind` picks the provider and
// everything else is that kind's own. A plugin instance reads it back as
// `inst.options` (see Support.kt).
//
// A port of typescript/src/provider/support.ts, which is canonical.

package KOTLINPACKAGE.feature.secrets.sekreto

/**
 * Logging in to a vault instead of being handed a token. `method` is
 * `kubernetes` or `approle`; `mount` defaults to the method name.
 */
data class AuthSpec(
    val method: String,
    val mount: String? = null,
    /** kubernetes: the Vault role to log in as. */
    val role: String? = null,
    /** kubernetes: the service-account JWT itself (tests). */
    val jwt: String? = null,
    /** kubernetes: where the JWT lives; the conventional pod path by default. */
    val jwtfile: String? = null,
    /** approle: the role and secret ids. */
    val roleid: String? = null,
    val secretid: String? = null,
) {
    /**
     * Printed without its credentials.
     *
     * A `data class` generates a `toString` that prints every field, so
     * `logger.error("bad chain: $specs")` - which is what someone writes
     * when a chain will not build - would put the service-account JWT and
     * the AppRole secret id in the log. Fields that hold a credential
     * report whether they are set, never what they are.
     */
    override fun toString(): String =
        "AuthSpec(method=$method, mount=$mount, role=$role, jwtfile=$jwtfile, " +
            "roleid=$roleid, jwt=${setornot(jwt)}, secretid=${setornot(secretid)})"
}

/** What a credential field reports about itself. */
internal fun setornot(value: String?): String =
    if (value.isNullOrEmpty()) "[unset]" else "[set]"

/**
 * The declarative form of a provider, as used in config and in the shared
 * spec. `kind` picks the provider; everything else is that kind's own.
 */
data class ProviderSpec(
    val kind: String,
    /** The store name `Sekreto.getfrom` addresses. Defaults to `kind`. */
    val name: String? = null,
    val prefix: String? = null,
    /** dotenv: the file to read. secretspec: the declaration to read. */
    val file: String? = null,
    /** memory: literal values, keyed like environment variables. */
    val values: Map<String, String>? = null,
    /** file: the directory of one-secret-per-file entries. */
    val dir: String? = null,
    /** hashicorp / boru (wire) / gcp / 1password / doppler / infisical: the base URL. */
    val addr: String? = null,
    /** hashicorp / boru (wire) / gcp / azure / 1password / doppler / infisical: the token. */
    val token: String? = null,
    /** hashicorp / boru (wire): the KV mount (default `secret`). */
    val mount: String? = null,
    /** hashicorp: KV engine version, 1 or 2 (default 2). */
    val kv: Int? = null,
    /** hashicorp: Vault Enterprise namespace (X-Vault-Namespace). */
    val vaultnamespace: String? = null,
    /** hashicorp: log in for a token instead of being handed one. */
    val auth: AuthSpec? = null,
    /** boru / secretspec: the executable to run (default: the kind's own
     * name). */
    val command: String? = null,
    /** secretspec: the profile to read (`--profile`). */
    val profile: String? = null,
    /** secretspec: which of ITS backends to read from (`--provider`), e.g.
     * `keyring` or `dotenv://.env`. Named `backend` here because `provider`
     * already means a sekreto provider. */
    val backend: String? = null,
    /** secretspec: the audit reason recorded for the read (`--reason`).
     * SecretSpec refuses to read without one. */
    val reason: String? = null,
    /** boru: the namespace qualifying the alias. */
    val namespace: String? = null,
    /** boru: the vault home, passed as BORU_HOME. */
    val home: String? = null,
    /** aws: region and credentials; the standard AWS_* variables fill the rest. */
    val region: String? = null,
    val keyid: String? = null,
    val secret: String? = null,
    val session: String? = null,
    /** gcp / doppler / infisical: the project, however that store names it. */
    val project: String? = null,
    /** azure: the Key Vault name or full URL. 1password: the vault name or id. */
    val vault: String? = null,
    /** azure: client-credential login. infisical: universal-auth login. */
    val tenant: String? = null,
    val clientid: String? = null,
    val clientsecret: String? = null,
    /** azure: where to log in / where IMDS answers. gcp: the metadata server. */
    val loginaddr: String? = null,
    val imdsaddr: String? = null,
    val metadataaddr: String? = null,
    /** azure: the Key Vault API version (default 7.4). */
    val apiversion: String? = null,
    /** doppler: the config slug (with `project`). */
    val config: String? = null,
    /** infisical: the environment slug and secret path. */
    val environment: String? = null,
    val path: String? = null,
) {
    /**
     * Printed without its credentials. See AuthSpec.toString: the generated
     * one would put the Vault token, the AWS secret access key and the
     * Azure client secret into whatever formatted it.
     */
    override fun toString(): String =
        "ProviderSpec(kind=$kind, name=$name, addr=$addr, token=${setornot(token)}, " +
            "secret=${setornot(secret)}, clientsecret=${setornot(clientsecret)}, auth=$auth)"
}
