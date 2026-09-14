// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (kotlin/plugins/Azuresecrets.kt)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// Azure Key Vault, as a voxgig/plugin definition.

package KOTLINPACKAGE.feature.secrets.sekreto.plugins

import KOTLINPACKAGE.feature.secrets.sekreto.Definition
import KOTLINPACKAGE.feature.secrets.sekreto.Provider
import KOTLINPACKAGE.feature.secrets.sekreto.Providers.checkaddr
import KOTLINPACKAGE.feature.secrets.sekreto.SekretoError
import KOTLINPACKAGE.feature.secrets.sekreto.flatname
import KOTLINPACKAGE.feature.secrets.sekreto.providerplugin

/**
 * Azure Key Vault.
 *
 * `api.token` reads secret `api-token` (dots flattened to `-`; Key Vault
 * names allow nothing else), current version. The token comes from
 * config, then a client-credentials login when tenant/clientid/
 * clientsecret are given, then the IMDS managed-identity endpoint - so on
 * Azure's own platform no credential configuration is needed.
 *
 * As with GCP, the IMDS call is plain http to a link-local host by
 * platform design and carries no credential; the login and vault
 * addresses are `checkaddr`-guarded.
 */
class Azuresecrets(
    private val vault: String? = null,
    private val token: String? = null,
    private val tenant: String? = null,
    private val clientid: String? = null,
    private val clientsecret: String? = null,
    private val loginaddr: String? = null,
    private val imdsaddr: String? = null,
    private val apiversion: String? = null,
) : Provider {

    // A configured token is kept forever; logged-in and IMDS tokens carry
    // expires_in and are renewed shortly before they run out.
    private var livetoken: String? = null
    private var renewat: Long = Long.MAX_VALUE

    private fun login(): String {
        if (!token.isNullOrEmpty()) {
            return token
        }

        if (!tenant.isNullOrEmpty() &&
            !clientid.isNullOrEmpty() &&
            !clientsecret.isNullOrEmpty()
        ) {
            val useloginaddr = first(loginaddr, "https://login.microsoftonline.com")
            checkaddr(useloginaddr)

            val url = trimslash(useloginaddr) + "/" + tenant + "/oauth2/v2.0/token"
            val form = "grant_type=client_credentials&client_id=" + uriescape(clientid) +
                "&client_secret=" + uriescape(clientsecret) +
                "&scope=" + uriescape("$RESOURCE/.default")

            val res = fetchjson(
                "POST",
                url,
                mapOf("content-type" to "application/x-www-form-urlencoded"),
                form,
            )

            val got = res.body?.dig("access_token")?.text
            if (200 != res.status || got.isNullOrEmpty()) {
                throw SekretoError("sekreto: azure login failed: ${res.status}")
            }

            renewat = renewtime(res.body?.dig("expires_in"))
            return got
        }

        val imds = trimslash(first(imdsaddr, "http://169.254.169.254")) +
            "/metadata/identity/oauth2/token?api-version=2018-02-01&resource=" +
            uriescape(RESOURCE)

        val res = fetchjson("GET", imds, mapOf("Metadata" to "true"))

        val got = res.body?.dig("access_token")?.text
        if (200 != res.status || got.isNullOrEmpty()) {
            throw SekretoError(
                "sekreto: azure: no token, no client credentials, and IMDS did not answer",
            )
        }

        renewat = renewtime(res.body?.dig("expires_in"))
        return got
    }

    override fun lookup(name: String): String? {
        val usevault = vault ?: ""
        if (usevault.isEmpty()) {
            throw SekretoError("sekreto: azure: no vault")
        }

        // Only an explicit scheme is a URL; a vault NAMED httpvault must
        // still become https://httpvault.vault.azure.net.
        val vaulturl =
            if (usevault.startsWith("http://") || usevault.startsWith("https://")) {
                usevault
            } else {
                "https://$usevault.vault.azure.net"
            }
        checkaddr(vaulturl)

        if (null == livetoken || System.currentTimeMillis() >= renewat) {
            livetoken = login()
        }

        val url = trimslash(vaulturl) + "/secrets/" + flatname(name, "-") +
            "?api-version=" + first(apiversion, "7.4")

        val res = fetchjson("GET", url, mapOf("authorization" to "Bearer $livetoken"))

        if (404 == res.status) {
            return null
        }

        if (200 != res.status) {
            throw SekretoError("sekreto: azure error: ${res.status}: ${bare(url)}")
        }

        return res.body?.dig("value")?.text
    }

    override fun describe(): String = "azuresecrets:${vault ?: ""}"

    private companion object {
        const val RESOURCE = "https://vault.azure.net"
    }
}

/** The `azuresecrets` provider kind, as a voxgig/plugin definition. A
 * consumer imports this and hands it to `Sekreto`; a consumer that does
 * not is a `Sekreto` that cannot build a `azuresecrets` chain entry. */
val azuresecrets: Definition = providerplugin("azuresecrets") { spec ->
    Azuresecrets(
        spec.vault, spec.token, spec.tenant, spec.clientid, spec.clientsecret,
        spec.loginaddr, spec.imdsaddr, spec.apiversion,
    )
}
