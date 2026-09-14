// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (kotlin/plugins/Doppler.kt)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// Doppler, as a voxgig/plugin definition.

package KOTLINPACKAGE.feature.secrets.sekreto.plugins

import KOTLINPACKAGE.feature.secrets.sekreto.Definition
import KOTLINPACKAGE.feature.secrets.sekreto.Provider
import KOTLINPACKAGE.feature.secrets.sekreto.Providers.checkaddr
import KOTLINPACKAGE.feature.secrets.sekreto.SekretoError
import KOTLINPACKAGE.feature.secrets.sekreto.envkey
import KOTLINPACKAGE.feature.secrets.sekreto.providerplugin

/**
 * Doppler.
 *
 * The whole config is downloaded once - Doppler's own bulk endpoint - and
 * answered from memory, like a remote .env: `api.token` is the
 * `API_TOKEN` entry. A service token is config-scoped, so project and
 * config are only needed with broader tokens.
 */
class Doppler(
    private val token: String? = null,
    private val project: String? = null,
    private val config: String? = null,
    private val addr: String? = null,
) : Provider {

    private var values: Map<String, String>? = null

    private fun load(): Map<String, String> {
        values?.let { return it }

        val useaddr = trimslash(first(addr, "https://api.doppler.com"))
        checkaddr(useaddr)

        var url = "$useaddr/v3/configs/config/secrets/download?format=json"
        if (!project.isNullOrEmpty()) {
            url += "&project=" + uriescape(project)
        }
        if (!config.isNullOrEmpty()) {
            url += "&config=" + uriescape(config)
        }

        val res = fetchjson(
            "GET",
            url,
            mapOf("authorization" to "Bearer ${token ?: ""}"),
        )

        val body = res.body?.asobj
        if (200 != res.status || null == body) {
            throw SekretoError("sekreto: doppler error: ${res.status}")
        }

        val loaded = LinkedHashMap<String, String>()
        for ((key, value) in body) {
            value.text?.let { loaded[key] = it }
        }

        values = loaded
        return loaded
    }

    override fun lookup(name: String): String? = load()[envkey(name)]

    override fun describe(): String =
        "doppler" + if (project.isNullOrEmpty()) "" else ":$project/${config ?: ""}"
}

/** The `doppler` provider kind, as a voxgig/plugin definition. A
 * consumer imports this and hands it to `Sekreto`; a consumer that does
 * not is a `Sekreto` that cannot build a `doppler` chain entry. */
val doppler: Definition = providerplugin("doppler") { spec ->
    Doppler(spec.token, spec.project, spec.config, spec.addr)
}
