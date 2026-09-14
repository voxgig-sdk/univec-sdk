// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (kotlin/plugins/Hashicorp.kt)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// HashiCorp Vault, as a voxgig/plugin definition.

package KOTLINPACKAGE.feature.secrets.sekreto.plugins

import KOTLINPACKAGE.feature.secrets.sekreto.AuthSpec
import KOTLINPACKAGE.feature.secrets.sekreto.Definition
import KOTLINPACKAGE.feature.secrets.sekreto.Json
import KOTLINPACKAGE.feature.secrets.sekreto.Provider
import KOTLINPACKAGE.feature.secrets.sekreto.Providers.checkaddr
import KOTLINPACKAGE.feature.secrets.sekreto.SekretoError
import KOTLINPACKAGE.feature.secrets.sekreto.providerplugin
import KOTLINPACKAGE.feature.secrets.sekreto.vaultref

import java.io.IOException
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Paths

/**
 * HashiCorp Vault.
 *
 * KV v2 (the default): `api.token` reads `{addr}/v1/{mount}/data/api` and
 * takes the `token` field of `data.data`. KV v1 (`kv: 1`) reads
 * `{addr}/v1/{mount}/api` and takes the field of `data`. A 404 means "not
 * here" - a miss - so a vault can sit in a chain with fallbacks.
 *
 * A Vault Enterprise namespace rides the X-Vault-Namespace header, on
 * logins as well as reads.
 *
 * Instead of being handed a token, the provider can log in: Kubernetes
 * auth (the pod's service-account JWT, from its conventional path) or
 * AppRole. A failed login is an error, never a miss - it means this store
 * could not answer at all.
 */
class Hashicorp(
    addr: String?,
    token: String? = null,
    mount: String? = null,
    kv: Int? = null,
    private val vaultnamespace: String? = null,
    private val auth: AuthSpec? = null,
) : Provider {

    private val addr: String = addr ?: ""
    private val mount: String = if (mount.isNullOrEmpty()) "secret" else mount
    private val kv: Int = kv ?: 2

    // The working token: a configured token is kept forever, a logged-in
    // token is renewed shortly before its lease runs out - a long-running
    // process must not keep presenting a token the vault already expired.
    private var livetoken: String? = if (token.isNullOrEmpty()) null else token
    private var renewat: Long = Long.MAX_VALUE

    init {
        // A version typo like kv: 3 must not quietly behave as v2 and
        // turn its 404s into misses; there is nothing safe to assume it
        // meant.
        if (1 != this.kv && 2 != this.kv) {
            throw SekretoError("sekreto: hashicorp: unsupported kv version: ${this.kv}")
        }
    }

    private fun baseheaders(): MutableMap<String, String> {
        val out = LinkedHashMap<String, String>()
        if (!vaultnamespace.isNullOrEmpty()) {
            out["X-Vault-Namespace"] = vaultnamespace
        }
        return out
    }

    private fun login(): String {
        val use = auth ?: throw SekretoError("sekreto: hashicorp: no token and no auth method")

        val authmount = first(use.mount, use.method)
        val url = trimslash(addr) + "/v1/auth/" + authmount + "/login"

        val body = when (use.method) {
            "kubernetes" -> {
                val jwt = use.jwt ?: run {
                    val file = use.jwtfile
                        ?: "/var/run/secrets/kubernetes.io/serviceaccount/token"
                    try {
                        String(
                            Files.readAllBytes(Paths.get(file)),
                            StandardCharsets.UTF_8,
                        ).trim()
                    } catch (err: IOException) {
                        throw SekretoError("sekreto: hashicorp: cannot read jwt file $file")
                    }
                }
                Json.obj("role" to Json.str(use.role ?: ""), "jwt" to Json.str(jwt))
            }
            "approle" -> Json.obj(
                "role_id" to Json.str(use.roleid ?: ""),
                "secret_id" to Json.str(use.secretid ?: ""),
            )
            else -> throw SekretoError(
                "sekreto: hashicorp: unknown auth method: ${use.method}",
            )
        }

        val res = fetchjson("POST", url, baseheaders(), Json.stringify(body))

        val got = res.body?.dig("auth", "client_token")?.text
        if (200 != res.status || got.isNullOrEmpty()) {
            throw SekretoError("sekreto: hashicorp login failed: ${res.status}: $url")
        }

        renewat = renewtime(res.body?.dig("auth", "lease_duration"))

        return got
    }

    override fun lookup(name: String): String? {
        checkaddr(addr)

        if (null == livetoken || System.currentTimeMillis() >= renewat) {
            livetoken = login()
        }

        val ref = vaultref(name)
        val base = trimslash(addr) + "/v1/" + mount
        val url = if (1 == kv) "$base/${ref.path}" else "$base/data/${ref.path}"

        val headers = baseheaders()
        headers["X-Vault-Token"] = livetoken ?: ""

        val res = fetchjson("GET", url, headers)

        if (404 == res.status) {
            return null
        }

        if (200 != res.status) {
            throw SekretoError("sekreto: hashicorp error: ${res.status}: $url")
        }

        val data = if (1 == kv) res.body?.dig("data") else res.body?.dig("data", "data")

        return data?.dig(ref.field)?.text
    }

    override fun describe(): String = "hashicorp:$addr/$mount"
}

/** The `hashicorp` provider kind, as a voxgig/plugin definition. A
 * consumer imports this and hands it to `Sekreto`; a consumer that does
 * not is a `Sekreto` that cannot build a `hashicorp` chain entry. */
val hashicorp: Definition = providerplugin("hashicorp") { spec ->
    Hashicorp(
        spec.addr, spec.token, spec.mount, spec.kv, spec.vaultnamespace, spec.auth,
    )
}
