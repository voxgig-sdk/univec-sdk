// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (kotlin/src/Support.kt)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// How a provider kind becomes a voxgig/plugin definition.
//
// This file is the whole bridge between the two libraries. A provider
// kind is a plugin `Definition` named after the kind; its `define` reads
// the instance's options as a `ProviderSpec`, builds the provider, and
// exports it under the key `provider`. `Sekreto` reads it back off the
// host. One helper makes every one of them, built-in or plugin, shipped
// or custom:
//
//     val mystore = providerplugin("mystore") { spec -> Mystore(spec.addr) }
//
// A port of typescript/src/provider/support.ts, which is canonical.

package KOTLINPACKAGE.feature.secrets.sekreto

import java.util.TreeMap
import KOTLINPACKAGE.feature.secrets.plugin.Inst
import KOTLINPACKAGE.feature.secrets.plugin.PluginError

/**
 * A voxgig/plugin definition.
 *
 * plugin's value model is `Any?`, and a definition is a map of `name` to
 * the kind and `define` to the callback - which is what makes a catalog a
 * data structure a document could produce. The alias exists so that a
 * `plugins` list reads as what it is rather than as `List<Map<String, Any?>>`.
 */
typealias Definition = Map<String, Any?>

/** The export key under which a provider definition publishes the
 * provider it built. `Sekreto` reads `<ref>/provider` off the host. */
const val PROVIDER_EXPORT: String = "provider"

/**
 * The voxgig/plugin error code a SekretoError travels under when it is
 * raised inside a definition's `define`.
 *
 * plugin wraps a code-less error raised by a callback as
 * `plugin_define_failed`, and keeps one that already carries a code. A
 * provider that refuses its own configuration - `kv: 3`, a missing
 * project - raises a SekretoError, and the spec pins that message byte
 * for byte, so it must come back out of the host exactly as it went in.
 * `providerplugin` gives it this code on the way in; `Sekreto` takes it
 * off on the way out. Nowhere else catches and rewraps.
 */
const val ERROR_CODE: String = "sekreto_error"

/**
 * A provider kind, as a voxgig/plugin definition.
 *
 * Nothing runs at `activate`: a provider opens nothing until its first
 * lookup, so there is nothing to capture - a provider that does hold a
 * resource acquires it there and lets the instance scope unwind it.
 */
fun providerplugin(kind: String, make: (ProviderSpec) -> Provider): Definition = mapOf(
    "name" to kind,
    // A kotlin lambda, so plugin's `run` sees a Function1 and calls it.
    "define" to { inst: Inst ->
        val provider = try {
            make(specof(inst.options))
        } catch (err: SekretoError) {
            val text = err.message ?: ""
            throw PluginError(ERROR_CODE, text, mapOf("ref" to inst.ref, "cause" to text))
        }

        inst.export(PROVIDER_EXPORT, provider)
    },
)

// --- the spec across the plugin boundary -----------------------------
//
// plugin's options are its own value model - a map of strings to
// `null`, Boolean, Double, String, List and Map - and sekreto's spec is a
// typed data class, so the two are written out field by field rather than
// reflected over. `optionsof` is what `Sekreto.declare` hands to
// `host.load`; `specof` is what a definition's `define` reads back. They
// are inverses, and `PluginsTest.a_provider_spec_survives_the_plugin_boundary`
// is what says so - a field added to one and forgotten in the other would
// otherwise be lost in silence, and only for the kinds no conformance
// case exercises.

private fun put(out: MutableMap<String, Any?>, key: String, value: Any?) {
    if (null != value) {
        out[key] = value
    }
}

private fun str(options: Map<String, Any?>, key: String): String? = options[key] as? String

/** A ProviderSpec as plugin instance options. */
fun optionsof(spec: ProviderSpec): Map<String, Any?> {
    val out = TreeMap<String, Any?>()

    out["kind"] = spec.kind
    put(out, "name", spec.name)
    put(out, "prefix", spec.prefix)
    put(out, "file", spec.file)
    put(out, "values", spec.values?.let { TreeMap<String, Any?>(it) })
    put(out, "dir", spec.dir)
    put(out, "addr", spec.addr)
    put(out, "token", spec.token)
    put(out, "mount", spec.mount)
    // Every number in plugin's model is a Double, JSON's one number type.
    put(out, "kv", spec.kv?.toDouble())
    put(out, "vaultnamespace", spec.vaultnamespace)
    put(
        out, "auth",
        spec.auth?.let { auth ->
            val nested = TreeMap<String, Any?>()
            nested["method"] = auth.method
            put(nested, "mount", auth.mount)
            put(nested, "role", auth.role)
            put(nested, "jwt", auth.jwt)
            put(nested, "jwtfile", auth.jwtfile)
            put(nested, "roleid", auth.roleid)
            put(nested, "secretid", auth.secretid)
            nested
        },
    )
    put(out, "command", spec.command)
    put(out, "profile", spec.profile)
    put(out, "backend", spec.backend)
    put(out, "reason", spec.reason)
    put(out, "namespace", spec.namespace)
    put(out, "home", spec.home)
    put(out, "region", spec.region)
    put(out, "keyid", spec.keyid)
    put(out, "secret", spec.secret)
    put(out, "session", spec.session)
    put(out, "project", spec.project)
    put(out, "vault", spec.vault)
    put(out, "tenant", spec.tenant)
    put(out, "clientid", spec.clientid)
    put(out, "clientsecret", spec.clientsecret)
    put(out, "loginaddr", spec.loginaddr)
    put(out, "imdsaddr", spec.imdsaddr)
    put(out, "metadataaddr", spec.metadataaddr)
    put(out, "apiversion", spec.apiversion)
    put(out, "config", spec.config)
    put(out, "environment", spec.environment)
    put(out, "path", spec.path)

    return out
}

/** Plugin instance options as a ProviderSpec. */
fun specof(options: Map<String, Any?>): ProviderSpec {
    val values = (options["values"] as? Map<*, *>)?.let { given ->
        LinkedHashMap<String, String>().also { out ->
            given.forEach { (key, value) -> out["$key"] = "$value" }
        }
    }

    val auth = (options["auth"] as? Map<*, *>)?.let { given ->
        AuthSpec(
            method = given["method"] as? String ?: "",
            mount = given["mount"] as? String,
            role = given["role"] as? String,
            jwt = given["jwt"] as? String,
            jwtfile = given["jwtfile"] as? String,
            roleid = given["roleid"] as? String,
            secretid = given["secretid"] as? String,
        )
    }

    return ProviderSpec(
        kind = str(options, "kind") ?: "",
        name = str(options, "name"),
        prefix = str(options, "prefix"),
        file = str(options, "file"),
        values = values,
        dir = str(options, "dir"),
        addr = str(options, "addr"),
        token = str(options, "token"),
        mount = str(options, "mount"),
        kv = (options["kv"] as? Number)?.toInt(),
        vaultnamespace = str(options, "vaultnamespace"),
        auth = auth,
        command = str(options, "command"),
        profile = str(options, "profile"),
        backend = str(options, "backend"),
        reason = str(options, "reason"),
        namespace = str(options, "namespace"),
        home = str(options, "home"),
        region = str(options, "region"),
        keyid = str(options, "keyid"),
        secret = str(options, "secret"),
        session = str(options, "session"),
        project = str(options, "project"),
        vault = str(options, "vault"),
        tenant = str(options, "tenant"),
        clientid = str(options, "clientid"),
        clientsecret = str(options, "clientsecret"),
        loginaddr = str(options, "loginaddr"),
        imdsaddr = str(options, "imdsaddr"),
        metadataaddr = str(options, "metadataaddr"),
        apiversion = str(options, "apiversion"),
        config = str(options, "config"),
        environment = str(options, "environment"),
        path = str(options, "path"),
    )
}
