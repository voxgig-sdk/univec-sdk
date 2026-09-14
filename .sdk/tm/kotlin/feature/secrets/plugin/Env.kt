// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (kotlin/src/Env.kt)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package KOTLINPACKAGE.feature.secrets.plugin

import java.util.TreeMap

/**
 * Environment overrides (section 9.5) - level 7 of the ladder.
 *
 * One prefix, so nothing drifts: `VOXGIG_PLUGIN_*`.
 *
 *   VOXGIG_PLUGIN_PROFILE            the profile name
 *   VOXGIG_PLUGIN_<REF>_<PATH>       one option
 *   VOXGIG_PLUGIN_ACTIVE/INACTIVE    comma-separated refs, INACTIVE wins
 *
 * THE ENCODING IS LOSSY, AND THIS SAYS SO RATHER THAN PRETENDING OTHERWISE.
 * Ref and path are upper-snake with `$` -> `__` and `.` -> `_`. But `_` is
 * legal in a name and in a tag, and the mapping folds case, so `retry$fast`
 * and `retry__fast` both encode to `RETRY__FAST`.
 *
 * Rather than restrict a grammar the rest of the stack already uses, the host
 * DETECTS THE COLLISION: it encodes every ref it holds, and a key two refs
 * claim is `plugin_env_ambiguous`, naming both.
 */
object Env {

    private const val PREFIX = "VOXGIG_PLUGIN_"

    /** `retry$fast` -> `RETRY__FAST`. */
    fun encodeRef(ref: String): String =
        upperAscii(ref.replace("$", "__").replace(".", "_"))

    // ASCII, AND SPELLED THE LONG WAY, FOR TWO REASONS.
    //
    // LOCALE: an environment variable name must not depend on the JVM's
    // default locale. `String.toUpperCase()` does -- in tr-TR it maps "i" to
    // "\u0130", so `retry$fast` would encode to a name no shell can set.
    //
    // COMPILER: the fix the deprecation warning suggests, `uppercase()`, is
    // Kotlin 1.5+. CI compiles this port with ubuntu's `kotlin` package,
    // which is 1.3.31, where that name does not resolve at all. `toUpperCase`
    // is deprecated from 1.5 and the Makefile builds with -Werror, so the
    // stdlib call fails on ONE of the two compilers whichever one is chosen.
    // A char range resolves on both and warns on neither.
    private fun upperAscii(s: String): String =
        buildString(s.length) { for (c in s) append(if (c in 'a'..'z') c - 32 else c) }

    private fun lowerAscii(s: String): String =
        buildString(s.length) { for (c in s) append(if (c in 'A'..'Z') c + 32 else c) }

    /**
     * Values parse as JSON, FALLING BACK TO STRING - so `8080` is a number,
     * `true` is a boolean, `{"a":1}` is a map, and `hello` is the string it
     * looks like rather than a parse error.
     */
    private fun parseValue(value: Any?): Any? = try {
        Json.parse(value as String)
    } catch (e: Exception) {
        value
    }

    private fun split(value: Any?): List<String> =
        value.toString().split(",").map { it.trim() }.filter { "" != it }

    private fun checkReserved(ref: String, reserved: List<*>) {
        if (!reserved.contains(Refs.refName(ref))) return
        Types.fail(
            "plugin_ref_reserved", "ref is reserved by the host: $ref",
            mapOf("ref" to ref)
        )
    }

    fun applyEnv(input: Any?): Map<String, Any?> {
        val env = Types.get(input, "env") ?: emptyMap<String, Any?>()
        val refs = ((Types.get(input, "refs") ?: emptyList<Any?>()) as List<*>)
            .map { Refs.canonRef(it) }
        val reserved = (Types.get(input, "reserved") ?: emptyList<Any?>()) as List<*>

        val options = TreeMap<String, Any?>()
        val active = ArrayList<String>()
        val inactive = ArrayList<String>()
        val out = TreeMap<String, Any?>()
        out["options"] = options
        out["active"] = active
        out["inactive"] = inactive

        // Encode every ref the host holds, and refuse a key that two of them
        // claim. Done up front so the collision is reported even when no
        // environment variable exercises it - a latent ambiguity is still an
        // ambiguity, and finding it at deploy time is the failure this exists
        // to prevent.
        val byencoded = TreeMap<String, MutableList<String>>()
        for (ref in refs) byencoded.getOrPut(encodeRef(ref)) { ArrayList() }.add(ref)
        for ((e, group) in byencoded) {
            if (1 >= group.size) continue
            val pair = group.sorted()
            Types.fail(
                "plugin_env_ambiguous",
                "refs collide in the environment encoding as $e: ${pair.joinToString(", ")}",
                mapOf("encoded" to e, "refs" to pair)
            )
        }

        // Longest encoded ref first, so `retry$fast` wins over `retry` on
        // `RETRY__FAST_MIN`. Shortest-first would read the tag as a path.
        val encoded = Types.stableSortBy(byencoded.keys.toList()) { listOf(-it.length) }

        for (key in Types.keys(env)) {
            if (!key.startsWith(PREFIX)) continue
            val rest = key.substring(PREFIX.length)

            if ("PROFILE" == rest) {
                out["profile"] = Types.get(env, key)
                continue
            }

            if ("ACTIVE" == rest || "INACTIVE" == rest) {
                for (raw in split(Types.get(env, key))) {
                    val ref = Refs.canonRef(raw)
                    // The reservation covers EVERY input layer (section 9.1).
                    // VOXGIG_PLUGIN_INACTIVE=station is easier to set than
                    // editing a config file, and INACTIVE has the final word -
                    // so guarding documents alone would leave the one lever
                    // this mechanism exists to deny wide open.
                    checkReserved(ref, reserved)
                    if ("ACTIVE" == rest) active.add(ref) else inactive.add(ref)
                }
                continue
            }

            val enc = encoded.firstOrNull { rest == it || rest.startsWith(it + "_") }
                ?: continue // not for any ref this host holds

            val ref = byencoded[enc]!![0]
            checkReserved(ref, reserved)

            if (rest == enc) continue // a ref with no path sets nothing

            val path = lowerAscii(rest.substring(enc.length + 1)).split("_")

            var node = options[ref]
            if (node !is MutableMap<*, *>) {
                node = TreeMap<String, Any?>()
                options[ref] = node
            }
            @Suppress("UNCHECKED_CAST")
            var cursor = node as MutableMap<String, Any?>
            for (i in 0 until path.size - 1) {
                var child = cursor[path[i]]
                if (child !is MutableMap<*, *>) {
                    child = TreeMap<String, Any?>()
                    cursor[path[i]] = child
                }
                @Suppress("UNCHECKED_CAST")
                cursor = child as MutableMap<String, Any?>
            }
            cursor[path[path.size - 1]] = parseValue(Types.get(env, key))
        }

        return out
    }
}
