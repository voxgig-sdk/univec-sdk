// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (kotlin/src/Refs.kt)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package KOTLINPACKAGE.feature.secrets.plugin

/**
 * Identity: name+tag, written `name$tag` (section 4).
 *
 * The four pure functions, and the whole of what `ref` pins. They are the
 * first thing a new port implements and the first corpus section it passes.
 */
object Refs {

    /**
     * Section 4: `[a-zA-Z@][a-zA-Z0-9.~_\-/]*`, max 1024.
     *
     * NO `^` AND NO `$`, because `Regex.matches` requires the WHOLE input to
     * match - it is `Matcher.matches`, not `find`. Writing the anchors would
     * be harmless and misleading: it would suggest they are what rejects
     * `"abc\n"`, and they are not. Reaching for `containsMatchIn` here is
     * what would admit a ref grammar with a newline in it, and
     * `ref/name#trailing-newline` says so.
     */
    private val NAME_RE = Regex("[a-zA-Z@][a-zA-Z0-9.~_\\-/]*")

    /**
     * Section 4: `[a-zA-Z0-9.~_-]+`, max 1024, or empty.
     *
     * The asymmetry with a name is deliberate: a tag MAY start with a digit
     * because auto-tagging assigns integer tags (`stripe$1`), and a tag
     * admits neither `@` nor `/` because a name is a package specifier and a
     * tag is not.
     */
    private val TAG_RE = Regex("[a-zA-Z0-9.~_-]+")

    private const val REF_MAX = 1024

    fun checkName(name: Any?): Boolean =
        name is String && "" != name && name.length <= REF_MAX &&
            NAME_RE.matches(name)

    fun checkTag(tag: Any?): Boolean {
        if (tag !is String) return false
        // The empty tag is an ordinary tag (section 4 rule 2). The
        // single-instance case writes no tag and never learns tags exist.
        if ("" == tag) return true
        return tag.length <= REF_MAX && TAG_RE.matches(tag)
    }

    /**
     * `name$tag` -> the pair. Canonicalizing: `stripe$` and `stripe` both
     * give tag "".
     */
    fun parseRef(str: Any?): Map<String, Any?> {
        if (str !is String) Types.fail("plugin_bad_name", "ref must be a string")
        // Split on the FIRST `$`. Nothing in the grammar decides this - `$`
        // is in neither character class - so the corpus is the arbiter
        // (section 4 rule 5), and it picks the split that blames the part
        // actually at fault: `a$b$c` is a good name with a bad tag, not the
        // reverse.
        val cut = str.indexOf('$')
        val name = if (0 > cut) str else str.substring(0, cut)
        val tag = if (0 > cut) "" else str.substring(cut + 1)

        if (!checkName(name)) {
            Types.fail("plugin_bad_name", "invalid plugin name: $name", mapOf("name" to name))
        }
        if (!checkTag(tag)) {
            Types.fail(
                "plugin_bad_tag", "invalid plugin tag: $tag",
                mapOf("name" to name, "tag" to tag)
            )
        }
        val out = java.util.TreeMap<String, Any?>()
        out["name"] = name
        out["tag"] = tag
        return out
    }

    /**
     * The pair -> `name$tag`. An empty tag NEVER writes the separator, which
     * is the half of canonicalization `formatRef` owns: parse tolerates
     * `stripe$`, format never produces it, so a round trip is idempotent.
     */
    @JvmOverloads
    fun formatRef(name: Any?, tag: Any? = null): String {
        val t = tag ?: ""
        if (!checkName(name)) {
            Types.fail("plugin_bad_name", "invalid plugin name: $name", mapOf("name" to name))
        }
        if (!checkTag(t)) {
            Types.fail(
                "plugin_bad_tag", "invalid plugin tag: $t",
                mapOf("name" to name, "tag" to t)
            )
        }
        return if ("" == t) name as String else "$name\$$t"
    }

    /**
     * The canonical spelling of a ref. Section 4 rule 5: ports must
     * canonicalize before comparison.
     */
    fun canonRef(str: Any?): String {
        val r = parseRef(str)
        return formatRef(r["name"], r["tag"])
    }

    /**
     * `canonRef` for the internal callers that want the input back unchanged
     * when it is not well formed. NEVER use it where a bad ref must be
     * reported - the corpus pins plugin_bad_name at every public entry.
     */
    fun canon(str: Any?): String = try {
        canonRef(str)
    } catch (e: PluginError) {
        str as String
    }

    fun refName(str: Any?): String = try {
        parseRef(str)["name"] as String
    } catch (e: PluginError) {
        str as String
    }
}
