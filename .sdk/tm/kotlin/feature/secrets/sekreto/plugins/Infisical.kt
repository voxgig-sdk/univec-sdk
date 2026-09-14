// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (kotlin/plugins/Infisical.kt)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// Infisical, as a voxgig/plugin definition.

package KOTLINPACKAGE.feature.secrets.sekreto.plugins

import KOTLINPACKAGE.feature.secrets.sekreto.Definition
import KOTLINPACKAGE.feature.secrets.sekreto.Json
import KOTLINPACKAGE.feature.secrets.sekreto.Provider
import KOTLINPACKAGE.feature.secrets.sekreto.Providers.checkaddr
import KOTLINPACKAGE.feature.secrets.sekreto.SekretoError
import KOTLINPACKAGE.feature.secrets.sekreto.envkey
import KOTLINPACKAGE.feature.secrets.sekreto.providerplugin

/**
 * Infisical.
 *
 * `api.token` reads the secret keyed `API_TOKEN` (Infisical's own
 * convention is environment-style keys) at a secret path in one
 * environment of a project. Auth is a token, or a universal-auth (machine
 * identity) login with clientid/clientsecret.
 */
class Infisical(
    private val addr: String? = null,
    private val token: String? = null,
    private val clientid: String? = null,
    private val clientsecret: String? = null,
    private val project: String? = null,
    private val environment: String? = null,
    private val path: String? = null,
) : Provider {

    // A configured token is kept forever; a universal-auth token carries
    // expiresIn and is renewed shortly before it runs out.
    private var livetoken: String? = null
    private var renewat: Long = Long.MAX_VALUE

    private fun login(useaddr: String): String {
        if (!token.isNullOrEmpty()) {
            return token
        }

        if (clientid.isNullOrEmpty() || clientsecret.isNullOrEmpty()) {
            throw SekretoError("sekreto: infisical: no token and no client credentials")
        }

        val body = Json.obj(
            "clientId" to Json.str(clientid),
            "clientSecret" to Json.str(clientsecret),
        )

        val res = fetchjson(
            "POST",
            "$useaddr/api/v1/auth/universal-auth/login",
            mapOf("content-type" to "application/json"),
            Json.stringify(body),
        )

        val got = res.body?.dig("accessToken")?.text
        if (200 != res.status || got.isNullOrEmpty()) {
            throw SekretoError("sekreto: infisical login failed: ${res.status}")
        }

        renewat = renewtime(res.body?.dig("expiresIn"))

        return got
    }

    override fun lookup(name: String): String? {
        val useaddr = trimslash(first(addr, "https://app.infisical.com"))
        checkaddr(useaddr)

        val useproject = project ?: ""
        val useenvironment = environment ?: ""
        if (useproject.isEmpty() || useenvironment.isEmpty()) {
            throw SekretoError("sekreto: infisical: no project/environment")
        }

        if (null == livetoken || System.currentTimeMillis() >= renewat) {
            livetoken = login(useaddr)
        }

        val url = "$useaddr/api/v3/secrets/raw/" + envkey(name) +
            "?workspaceId=" + uriescape(useproject) +
            "&environment=" + uriescape(useenvironment) +
            "&secretPath=" + uriescape(first(path, "/"))

        val res = fetchjson("GET", url, mapOf("authorization" to "Bearer $livetoken"))

        if (404 == res.status) {
            return null
        }

        if (200 != res.status) {
            throw SekretoError("sekreto: infisical error: ${res.status}")
        }

        return res.body?.dig("secret", "secretValue")?.text
    }

    override fun describe(): String =
        "infisical:${project ?: ""}/${environment ?: ""}"
}

/** The `infisical` provider kind, as a voxgig/plugin definition. A
 * consumer imports this and hands it to `Sekreto`; a consumer that does
 * not is a `Sekreto` that cannot build a `infisical` chain entry. */
val infisical: Definition = providerplugin("infisical") { spec ->
    Infisical(
        spec.addr, spec.token, spec.clientid, spec.clientsecret,
        spec.project, spec.environment, spec.path,
    )
}
