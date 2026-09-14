// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (kotlin/plugins/Onepassword.kt)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// 1Password Connect, as a voxgig/plugin definition.

package KOTLINPACKAGE.feature.secrets.sekreto.plugins

import KOTLINPACKAGE.feature.secrets.sekreto.Definition
import KOTLINPACKAGE.feature.secrets.sekreto.Provider
import KOTLINPACKAGE.feature.secrets.sekreto.Providers.checkaddr
import KOTLINPACKAGE.feature.secrets.sekreto.SekretoError
import KOTLINPACKAGE.feature.secrets.sekreto.checkname
import KOTLINPACKAGE.feature.secrets.sekreto.providerplugin

/**
 * 1Password, through a Connect server.
 *
 * The item titled `api.token` (titles keep their dots), in the named
 * vault. The value is the field with purpose PASSWORD, or the field
 * labelled `value`. A vault that cannot be found is an error - config
 * names it, so its absence is a broken store, not a missing secret.
 */
class Onepassword(
    private val addr: String? = null,
    private val token: String? = null,
    private val vault: String? = null,
) : Provider {

    private var vaultid: String? = null

    private fun auth(): Map<String, String> =
        mapOf("authorization" to "Bearer ${token ?: ""}")

    private fun resolvevault(useaddr: String): String {
        val want = vault ?: ""
        if (want.isEmpty()) {
            throw SekretoError("sekreto: onepassword: no vault")
        }

        val res = fetchjson("GET", "$useaddr/v1/vaults", auth())

        val list = res.body?.asarr
        if (200 != res.status || null == list) {
            throw SekretoError("sekreto: onepassword error: ${res.status}: listing vaults")
        }

        for (entry in list) {
            val id = entry.dig("id")?.text
            if (want == id || want == entry.dig("name")?.text) {
                return id ?: ""
            }
        }

        throw SekretoError("sekreto: onepassword: no vault named $want")
    }

    override fun lookup(name: String): String? {
        checkname(name)

        val useaddr = trimslash(addr ?: "")
        if (useaddr.isEmpty()) {
            throw SekretoError("sekreto: onepassword: no addr")
        }
        checkaddr(useaddr)

        val id = vaultid ?: resolvevault(useaddr).also { vaultid = it }

        val filter = uriescape("title eq \"$name\"")
        val found = fetchjson("GET", "$useaddr/v1/vaults/$id/items?filter=$filter", auth())

        val items = found.body?.asarr
        if (200 != found.status || null == items) {
            throw SekretoError("sekreto: onepassword error: ${found.status}: finding $name")
        }

        if (items.isEmpty()) {
            return null
        }

        val item = fetchjson(
            "GET",
            "$useaddr/v1/vaults/$id/items/${items[0].dig("id")?.text}",
            auth(),
        )

        if (200 != item.status) {
            throw SekretoError("sekreto: onepassword error: ${item.status}: reading $name")
        }

        val fields = item.body?.dig("fields")?.asarr ?: emptyList()

        for (field in fields) {
            if ("PASSWORD" == field.dig("purpose")?.asstr) {
                return field.dig("value")?.text
            }
        }
        for (field in fields) {
            if ("value" == field.dig("label")?.asstr) {
                return field.dig("value")?.text
            }
        }

        return null
    }

    override fun describe(): String = "onepassword:${vault ?: ""}"
}

/** The `onepassword` provider kind, as a voxgig/plugin definition. A
 * consumer imports this and hands it to `Sekreto`; a consumer that does
 * not is a `Sekreto` that cannot build a `onepassword` chain entry. */
val onepassword: Definition = providerplugin("onepassword") { spec ->
    Onepassword(spec.addr, spec.token, spec.vault)
}
