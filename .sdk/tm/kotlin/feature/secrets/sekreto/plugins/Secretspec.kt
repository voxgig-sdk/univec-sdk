// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (kotlin/plugins/Secretspec.kt)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// SecretSpec, as a voxgig/plugin definition.

package KOTLINPACKAGE.feature.secrets.sekreto.plugins

import KOTLINPACKAGE.feature.secrets.sekreto.Definition
import KOTLINPACKAGE.feature.secrets.sekreto.Provider
import KOTLINPACKAGE.feature.secrets.sekreto.SekretoError
import KOTLINPACKAGE.feature.secrets.sekreto.envkey
import KOTLINPACKAGE.feature.secrets.sekreto.providerplugin

/**
 * SecretSpec (https://secretspec.dev).
 *
 * SecretSpec is a declaration - a `secretspec.toml` naming the secrets a
 * project needs - plus a chain of its own backends to satisfy them from.
 * That makes it the same shape as sekreto one level down, and the reason
 * to support it is the same reason sekreto exists: a project that has
 * already declared its secrets there should not have to declare them
 * again here.
 *
 * Read through its CLI, as boru is, because that is the interface it
 * offers a program in another language: `secretspec get API_TOKEN`
 * prints the value on stdout and nothing else. A sekreto name maps to a
 * SecretSpec key exactly as it maps to an environment variable -
 * `api.token` is `API_TOKEN` - which is the convention SecretSpec's own
 * examples use.
 *
 * `backend` selects one of SecretSpec's backends (`--provider`, e.g.
 * `keyring` or `dotenv://.env`) and is called `backend` here only
 * because `provider` already means something else in this library.
 *
 * A reason is required, not optional: SecretSpec records every read in
 * an audit log and refuses to read at all without one. sekreto sends
 * `sekreto` unless told otherwise, so the audit trail says which tool
 * asked.
 */
class Secretspec(
    command: String? = null,
    private val file: String? = null,
    private val profile: String? = null,
    private val backend: String? = null,
    private val reason: String? = null,
    private val prefix: String? = null,
) : Provider {

    private val command: String =
        if (command.isNullOrEmpty()) "secretspec" else command

    override fun lookup(name: String): String? {
        val key = envkey(name, prefix)

        val args = mutableListOf(command)
        if (!file.isNullOrEmpty()) {
            args.add("--file")
            args.add(file)
        }
        args.add("get")
        args.add(key)
        if (!backend.isNullOrEmpty()) {
            args.add("--provider")
            args.add(backend)
        }
        if (!profile.isNullOrEmpty()) {
            args.add("--profile")
            args.add(profile)
        }
        args.add("--reason")
        args.add(first(reason, "sekreto"))

        val (out, why, status) = runcmd(ProcessBuilder(args), command)

        if (0 == status) {
            // The value and one newline, and nothing else.
            return out.removeSuffix("\n")
        }

        if (secretspecmiss(why, key)) {
            return null
        }

        throw SekretoError(
            "sekreto: secretspec error: " + why.ifEmpty { "exit $status" },
        )
    }

    override fun describe(): String =
        "secretspec" + if (backend.isNullOrEmpty()) "" else ":$backend"
}

/**
 * Does this SecretSpec failure mean "no such secret" rather than "I could
 * not answer"?
 *
 * SecretSpec says `Secret 'API_TOKEN' not found` for both a name it does
 * not declare and one declared with no value, and both are misses: this
 * store does not hold it, so the chain carries on.
 *
 * MATCHED ON THE WHOLE PHRASE, NOT ON "not found". SecretSpec also says
 * `Provider backend 'keyring' not found`, which is a store that could not
 * answer at all - and reading that as a miss is the worst failure this
 * library has, because the chain then falls through to a weaker store
 * without saying so. The key is required to appear, so the two cannot be
 * confused.
 */
internal fun secretspecmiss(why: String, key: String): Boolean =
    why.contains("Secret '$key' not found")

/** The `secretspec` provider kind, as a voxgig/plugin definition. A
 * consumer imports this and hands it to `Sekreto`; a consumer that does
 * not is a `Sekreto` that cannot build a `secretspec` chain entry. */
val secretspec: Definition = providerplugin("secretspec") { spec ->
    Secretspec(
        spec.command, spec.file, spec.profile, spec.backend, spec.reason, spec.prefix,
    )
}
