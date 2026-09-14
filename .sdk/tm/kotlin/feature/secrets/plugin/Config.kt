// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (kotlin/src/Config.kt)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package KOTLINPACKAGE.feature.secrets.plugin

import java.util.TreeMap

/**
 * The declarative document (section 9): normalization, and the ten-level
 * precedence ladder.
 *
 * TWO FUNCTIONS, AND THE SPLIT BETWEEN THEM IS FORCED.
 *
 * `normalizeConfig` normalizes STRUCTURE and ENTRY KEYS. It does not merge
 * options, and cannot: section 9.4 makes merge behaviour a property of the
 * definition's option SHAPE, which normalization has never seen. A normalizer
 * that flattened the option layers would make `$MERGE: append` unimplementable
 * at load time, because the layers it must concatenate would already be
 * collapsed.
 *
 * `resolveOptions` applies the ladder, and it is the only place that knows the
 * shape.
 */
object Config {

    private val MERGE_WORDS = listOf("replace", "append")

    private class Entries {
        val map = TreeMap<String, Any?>()
        val order = ArrayList<String>()
    }

    /**
     * Both document forms reduce to {ref -> entry} plus the order the form
     * implies: array POSITION for the array form, sorted refs for the map
     * form.
     */
    private fun entries(src: Any?): Entries {
        val out = Entries()
        if (null == src) return out

        if (src is List<*>) {
            for (item in src) {
                val ref = Refs.canonRef(Types.get(item, "ref"))
                out.map[ref] = item
                out.order.add(ref)
            }
            return out
        }

        // Map-form refs arrive as KEYS, through a different path than an array
        // element's `ref` field - and must canonicalize the same way.
        for (key in Types.keys(src)) out.map[Refs.canonRef(key)] = Types.get(src, key)
        // Byte-wise, NOT locale-aware and NOT case-folded. All-lowercase refs
        // sort identically under all three, so only mixed input discriminates:
        // '@' is 0x40, uppercase 0x41-0x5A, lowercase 0x61-0x7A. A `TreeMap`
        // with no comparator uses `String.compareTo`, which is exactly that.
        out.order.addAll(out.map.keys)
        return out
    }

    private fun checkReserved(ref: String, reserved: List<*>) {
        if (!reserved.contains(Refs.refName(ref))) return
        Types.fail(
            "plugin_ref_reserved", "ref is reserved by the host: $ref",
            mapOf("ref" to ref)
        )
    }

    /**
     * PRESENCE decides, not truthiness and not null. A JSON `null` is a
     * present value in JavaScript (`undefined !== null`), so it must be one
     * here.
     */
    private fun pick(src: Any?, key: String, dflt: Any?): Any? =
        if (Types.has(src, key)) Types.get(src, key) else dflt

    fun normalizeConfig(input: Any?): Map<String, Any?> {
        val doc = Types.get(input, "doc") ?: emptyMap<String, Any?>()
        val keys = Types.get(input, "keys") ?: emptyMap<String, Any?>()
        val ikey = (Types.get(keys, "instance") ?: "instance") as String
        val dkey = (Types.get(keys, "default") ?: "default") as String
        val reserved = (Types.get(input, "reserved") ?: emptyList<Any?>()) as List<*>
        val profile = Types.get(input, "profile")

        // The rename is applied at TWO PLACES AND NO OTHERS: the document
        // root, and every profile.<name> overlay root (section 9.1). A rename
        // applied only at the root would leave `profile.prod.sdk` untranslated
        // and silently drop every environment override the host depends on.
        // Recursing further would be worse: option data is the definition's.
        val basedef = Types.get(doc, dkey) ?: emptyMap<String, Any?>()
        var overlay = if (null == profile) null
        else Types.get(Types.get(doc, "profile"), profile as String)
        if (overlay !is Map<*, *>) overlay = emptyMap<String, Any?>()
        val overdef = Types.get(overlay, dkey) ?: emptyMap<String, Any?>()

        val base = entries(Types.get(doc, ikey))
        val over = entries(Types.get(overlay, ikey))

        for (group in listOf(
            base.map.keys.toList(), over.map.keys.toList(),
            Types.keys(basedef), Types.keys(overdef)
        )) {
            for (ref in group) checkReserved(ref, reserved)
        }

        // A PARTIAL ARRAY IS NOT A FILTER (section 9.1). sdkgen learned this
        // the hard way: deriving order from a partial array silently dropped
        // config-activated features. Refs in the base but absent from the
        // overlay still load, in sorted position AFTER the listed ones. A
        // profile may also INTRODUCE a ref the base never declared. The
        // remainder keeps the BASE's own order.
        val order = ArrayList<String>()
        for (ref in over.order + base.order) if (!order.contains(ref)) order.add(ref)

        val instance = TreeMap<String, Any?>()
        order.forEachIndexed { i, ref ->
            val b = base.map[ref]
            val o = over.map[ref]

            // MERGE THE ENTRIES AS AUTHORED, THEN APPLY DEFAULTS TO THE RESULT
            // (section 9.3). A safety rule, not a tidiness one: if the overlay
            // had its defaults filled in before merging it would carry a
            // synthesized active:true and overwrite a base's false - silently
            // re-enabling a deliberately disabled integration in production.
            val block = pick(o, "order", pick(b, "order", null))

            // Option layers, levels 3-6, IN LADDER ORDER. Never merged here.
            val nm = Refs.refName(ref)
            val layers = ArrayList<Any?>()
            for (src in listOf(Types.get(basedef, nm), b, Types.get(overdef, nm), o)) {
                if (Types.has(src, "options")) layers.add(Types.get(src, "options"))
            }

            val ent = TreeMap<String, Any?>()
            ent["pos"] = i.toDouble()
            ent["active"] = pick(o, "active", pick(b, "active", true))
            ent["start"] = pick(o, "start", pick(b, "start", "eager"))
            ent["optionlayers"] = layers
            if (null != block) ent["order"] = block
            instance[ref] = ent
        }

        // `default` DECLARES NOTHING (section 9.3). It is a base for every
        // instance of that definition; it does not create one, and an entry
        // for a name with no instances is inert rather than an error - which
        // is what makes a shared library of defaults shippable.
        val defout = TreeMap<String, Any?>()
        for (k in Types.keys(basedef)) defout[k] = Types.get(basedef, k)
        for (k in Types.keys(overdef)) defout[k] = Types.get(overdef, k)

        val out = TreeMap<String, Any?>()
        out["instance"] = instance
        out["order"] = order
        out["default"] = defout
        return out
    }

    /**
     * Section 9.4: N is an integer of at least 1, and everything else is an
     * error.
     *
     * `{"deep": 0}` is rejected DESPITE having an obvious reading, because
     * "replace at this key" already has a spelling and two spellings for one
     * behaviour is the defect class this repo exists to avoid.
     */
    fun checkShape(shape: Any?) {
        if (shape !is Map<*, *>) return
        for (k in Types.keys(shape)) {
            val v = Types.get(shape, k)
            if (!Types.has(v, "\$MERGE")) continue
            val directive = Types.get(v, "\$MERGE")

            if (directive is String) {
                if (MERGE_WORDS.contains(directive)) continue
                Types.fail(
                    "plugin_shape_invalid", "invalid \$MERGE directive at $k: $directive",
                    mapOf("key" to k, "directive" to directive)
                )
            }
            if (Types.has(directive, "deep")) {
                val n = Types.get(directive, "deep")
                // Every number here is a `Double`, so "an integer of at least
                // 1" is "a whole double of at least 1"; `true` is a `Boolean`
                // and reaches neither branch.
                val asInt = Types.asInt(n)
                if (null != asInt && n is Double && 1 <= asInt) continue
                Types.fail(
                    "plugin_shape_invalid", "invalid \$MERGE deep at $k: ${Json.write(n)}",
                    mapOf("key" to k, "directive" to directive)
                )
            }
            Types.fail(
                "plugin_shape_invalid",
                "invalid \$MERGE directive at $k: ${Json.write(directive)}",
                mapOf("key" to k, "directive" to directive)
            )
        }
    }

    /** The shape's non-directive values are the level-1 defaults. */
    private fun defaultsOf(shape: Any?): Map<String, Any?> {
        val out = TreeMap<String, Any?>()
        for (k in Types.keys(shape)) {
            val v = Types.get(shape, k)
            if (Types.has(v, "\$MERGE")) continue
            out[k] = v
        }
        return out
    }

    private fun optsOf(src: Any?, key: String): Any? {
        if (null == src) return null
        // The array form is equivalent to the map form (section 9.1).
        if (src is List<*>) {
            for (item in src) {
                if (Refs.canonRef(Types.get(item, "ref")) == key) {
                    return Types.get(item, "options")
                }
            }
            return null
        }
        for (k in Types.keys(src)) {
            if (Refs.canonRef(k) != key) continue
            val entry = Types.get(src, k)
            return if (entry is Map<*, *>) Types.get(entry, "options") else null
        }
        return null
    }

    /** Merge N levels below this key, replace below that. */
    private fun deepTo(base: Any?, over: Any?, n: Int): Any? {
        if (0 >= n) return over
        if (base !is Map<*, *> || over !is Map<*, *>) return over
        val out = TreeMap<String, Any?>()
        for (k in Types.keys(base)) out[k] = Types.get(base, k)
        for (k in Types.keys(over)) out[k] = deepTo(out[k], Types.get(over, k), n - 1)
        return out
    }

    /**
     * Merge ONE layer onto the accumulator, honouring the shape's directives.
     * The directive holds at EVERY precedence level, not only between document
     * levels - section 9.4 makes it a property of the shape, which does not
     * know which layer a value arrived from.
     */
    private fun mergeOne(base: Any?, over: Any?, shape: Any?): Any? {
        if (null == over) return base
        if (base !is Map<*, *> || over !is Map<*, *>) return over

        val out = TreeMap<String, Any?>()
        for (k in Types.keys(base)) out[k] = Types.get(base, k)

        for (k in Types.keys(over)) {
            val o = Types.get(over, k)
            val b = out[k]
            val directive = Types.get(Types.get(shape, k), "\$MERGE")

            when {
                "replace" == directive -> out[k] = o
                "append" == directive -> {
                    val bl = if (b is List<*>) b else emptyList<Any?>()
                    val ol = if (o is List<*>) o else listOf(o)
                    out[k] = bl + ol
                }
                Types.has(directive, "deep") ->
                    out[k] = deepTo(b, o, Types.asInt(Types.get(directive, "deep"))!!)
                // Library default: deep for maps, REPLACE for lists.
                // struct.merge is element-wise by index, which for option maps
                // is nearly always wrong - ["a"] over ["x","y","z"] yielding
                // ["a","y","z"] is the defect station hit on
                // secrets.providers.
                else -> out[k] = if (b is Map<*, *> && o is Map<*, *>) {
                    mergeOne(b, o, null)
                } else {
                    o
                }
            }
        }
        return out
    }

    fun resolveOptions(input: Any?): Map<String, Any?> {
        val shape = Types.get(input, "shape") ?: emptyMap<String, Any?>()
        checkShape(shape)

        val ref = Refs.canonRef(Types.get(input, "ref"))
        val name = Refs.refName(ref)
        val doc = Types.get(input, "doc") ?: emptyMap<String, Any?>()
        val profile = Types.get(input, "profile")

        var overlay = if (null == profile) null
        else Types.get(Types.get(doc, "profile"), profile as String)
        if (overlay !is Map<*, *>) overlay = emptyMap<String, Any?>()

        // ONE ordered merge, lowest to highest. Levels 3-6 are not two
        // namespaces collapsed separately and composed afterwards: that
        // inverts the rule that PROFILE SPECIFICITY OUTRANKS DEFINITION
        // SPECIFICITY, so a prod per-definition default would lose to a base
        // instance value.
        val layers = listOf(
            defaultsOf(shape),                              // 1
            Types.get(input, "hostdefaults"),               // 2
            optsOf(Types.get(doc, "default"), name),        // 3
            optsOf(Types.get(doc, "instance"), ref),        // 4
            optsOf(Types.get(overlay, "default"), name),    // 5
            optsOf(Types.get(overlay, "instance"), ref),    // 6
            Types.get(input, "env"),                        // 7
            Types.get(input, "hostoptions"),                // 8
            Types.get(input, "loadoptions"),                // 9
            Types.get(input, "patch")                       // 10
        )

        var out: Any? = TreeMap<String, Any?>()
        for (layer in layers) {
            if (null == layer) continue
            out = mergeOne(out, layer, shape)
        }
        @Suppress("UNCHECKED_CAST")
        return out as Map<String, Any?>
    }
}
