// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (kotlin/plugins/Boru.kt)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// A boru vault, as a voxgig/plugin definition.

package KOTLINPACKAGE.feature.secrets.sekreto.plugins

import KOTLINPACKAGE.feature.secrets.sekreto.Definition
import KOTLINPACKAGE.feature.secrets.sekreto.Provider
import KOTLINPACKAGE.feature.secrets.sekreto.Providers.checkaddr
import KOTLINPACKAGE.feature.secrets.sekreto.SekretoError
import KOTLINPACKAGE.feature.secrets.sekreto.checkname
import KOTLINPACKAGE.feature.secrets.sekreto.providerplugin

/**
 * A boru vault (https://github.com/boru-lang/boru).
 *
 * Two ways in, both boru's own.
 *
 * With no `addr`, the CLI: `boru vault get --reveal <alias>` prints the
 * secret on stdout and nothing else. The passphrase is read by boru
 * itself from `BORU_VAULT_PASSPHRASE`; sekreto never accepts it as config
 * and never puts it on a command line, where it would show up in the
 * process table.
 *
 * With an `addr`, boru's wire protocol: `boru vault serve` publishes a
 * read-only, HashiCorp-shaped provision API (boru's
 * design/VAULT-WIRE-PROTOCOL.0.md), authenticated by a capability token
 * from `boru vault grant`. A sekreto name is already a valid boru alias,
 * and boru aliases keep their dots, so `api.token` is the single path
 * segment `api.token` - not the `api`/`token` split a HashiCorp KV gets.
 * The value is the `value` field. A 404 is a miss; anything else the
 * server refuses (a revoked capability, a sealed vault) is an error.
 *
 * boru's `vault proxy` and `vault mcp` remain out of bounds: they are a
 * credential *broker*, built precisely so the caller never receives the
 * credential. `vault serve` is the provision endpoint, built to hand the
 * value back - that is the one sekreto uses.
 */
class Boru(
    command: String? = null,
    private val namespace: String? = null,
    private val home: String? = null,
    addr: String? = null,
    token: String? = null,
    mount: String? = null,
) : Provider {

    private val command: String = if (command.isNullOrEmpty()) "boru" else command
    private val addr: String = if (null == addr) "" else trimslash(addr)
    private val token: String = token ?: ""
    private val mount: String = if (mount.isNullOrEmpty()) "secret" else mount

    override fun lookup(name: String): String? {
        checkname(name)

        if (addr.isNotEmpty()) {
            return wirelookup(name)
        }

        val alias = if (namespace.isNullOrEmpty()) name else "$namespace:$name"

        val builder = ProcessBuilder(command, "vault", "get", "--reveal", alias)

        if (!home.isNullOrEmpty()) {
            builder.environment()["BORU_HOME"] = home
        }

        val (out, why, status) = runcmd(builder, command)

        if (0 == status) {
            // boru prints the value and one newline, and nothing else.
            return out.removeSuffix("\n")
        }

        // "no alias named" is boru saying it does not hold this secret,
        // which is a miss: the chain carries on to the next provider. A
        // locked vault or a wrong passphrase is not a miss - treating it
        // as one would fall through to a weaker store without saying so.
        if (borumiss(why)) {
            return null
        }

        throw SekretoError(
            "sekreto: boru vault error: " + why.ifEmpty { "exit $status" },
        )
    }

    private fun wirelookup(name: String): String? {
        checkaddr(addr)

        // The dotted name stays one path segment: boru aliases keep dots.
        val alias = if (namespace.isNullOrEmpty()) name else "$namespace/$name"
        val url = "$addr/v1/$mount/data/$alias"

        val res = fetchjson("GET", url, mapOf("X-Vault-Token" to token))

        if (404 == res.status) {
            return null
        }

        if (200 != res.status) {
            throw SekretoError("sekreto: boru serve error: ${res.status}: $url")
        }

        return res.body?.dig("data", "data", "value")?.text
    }

    override fun describe(): String {
        if (addr.isNotEmpty()) {
            return "boru:$addr"
        }
        return "boru" + if (namespace.isNullOrEmpty()) "" else ":$namespace"
    }
}

/**
 * Does this boru failure mean "no such secret" rather than "I could not
 * answer"? Matched on boru's own wording for a missing alias.
 */
internal fun borumiss(why: String): Boolean = why.contains("no alias named")

/** The `boru` provider kind, as a voxgig/plugin definition. A
 * consumer imports this and hands it to `Sekreto`; a consumer that does
 * not is a `Sekreto` that cannot build a `boru` chain entry. */
val boru: Definition = providerplugin("boru") { spec ->
    Boru(
        spec.command, spec.namespace, spec.home, spec.addr, spec.token, spec.mount,
    )
}
