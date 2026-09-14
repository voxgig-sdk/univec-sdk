// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (kotlin/src/Point.kt)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package KOTLINPACKAGE.feature.secrets.plugin

/**
 * Extension points (section 6). Three kinds, chosen because they are what
 * the two existing systems actually needed, and no more.
 *
 * A PLUGIN NEVER MUTATES THE HOST. That inversion is what makes deactivation
 * possible: sdkgen's `utility.fetcher = wrapped` is not undoable, but "this
 * instance holds slot 3 of the request chain" is undoable in O(1). OSGi named
 * it the whiteboard pattern in 2004, in a paper called *Listeners Considered
 * Harmful*, and for exactly this reason.
 */

/**
 * EVERY BINDING IS ARITY TWO, `(next, arg)`, hook and chain alike. `next` is
 * null for a hook. One signature means `Point` does not have to know which
 * kind of point it is holding - and the kind is the HOST's property, not the
 * binding's.
 */
typealias BindingFn = (Any?, Any?) -> Any?

/** A live binding. An internal shape, never a corpus value. */
data class Binding(
    val ref: String,
    val point: String,
    val fn: BindingFn,
    val band: Int
)

/** The winner and the losers on a provider point. */
data class Picked(val winner: Binding?, val shadowed: List<String>)

object Point {

    /**
     * Section 6.1: "fan-out" is not one answer but four. In a language with
     * asynchrony, "call every binding" hides a decision - start them all and
     * wait, await each in turn, or do not wait - and a design that leaves it
     * unsaid gets four different answers from four ports, in the concurrency
     * behaviour of production code no corpus entry happens to cover.
     *
     * KOTLIN IS A PORT WHERE THAT IS LOUD: a `suspend fun` host is one
     * keyword away, and it would make every hook point a suspension and every
     * ordering assertion a race. The host stays blocking (section 5.2) and
     * the modes stay data.
     */
    val modes = listOf("emit", "parallel", "serial", "bail")

    /** Fan-out. Return values are ignored except in `bail`. */
    fun pointEmit(bindings: List<Binding>, mode: String, arg: Any?): Any? {
        if ("bail" == mode) {
            // Stops at the first binding that RETURNS A VALUE - the "handled,
            // stop" case. A `null` RETURN DECLINES (section 6.1): kotlin has
            // one way to say nothing, and the model's rule is written to that
            // rather than to JavaScript's null/undefined pair. `null !=`, NOT
            // truthiness - `false` is a value.
            for (b in bindings) {
                val v = b.fn(null, arg)
                if (null != v) return v
            }
            return null
        }

        val errors = ArrayList<String>()
        for (b in bindings) {
            try {
                b.fn(null, arg)
            } catch (e: Exception) {
                // `emit` raises synchronously; the collecting modes gather.
                if ("emit" == mode) throw e
                errors.add(Types.messageOf(e))
            }
        }
        return if ("emit" == mode) null else errors
    }

    /**
     * Composition: b1(b2(b3(base))), FIRST BINDING OUTERMOST (section 6.2).
     *
     * Recomputed by the host whenever the live set changes, and cached
     * between changes. Plugins receive `next` as an argument; they never see
     * or store the previous value of anything. A plugin that stashes `next`
     * and calls it after deactivation is a bug the host cannot prevent, and
     * this says so rather than pretending otherwise.
     */
    fun compose(bindings: List<Binding>, base: (Any?) -> Any?): (Any?) -> Any? {
        var next = base
        for (i in bindings.indices.reversed()) {
            // `fn` and `inner` are declared INSIDE the loop, so each layer
            // closes over its own pair. Kotlin captures the variable rather
            // than the value, and hoisting either would leave every layer
            // calling the last one.
            val fn = bindings[i].fn
            val inner = next
            next = { arg -> fn(inner, arg) }
        }
        return next
    }

    /**
     * At most one live implementation (section 6.3). The winner is the
     * highest band, ties broken by ref sort, and THE LOSERS ARE VISIBLE
     * rather than silently ignored.
     */
    fun pointProvider(bindings: List<Binding>, spec: Any?): Picked {
        if (bindings.isEmpty()) return Picked(null, emptyList())

        if (Types.truthy(Types.get(spec, "exclusive")) && 1 < bindings.size) {
            val refs = bindings.map { it.ref }.sorted()
            Types.fail(
                "plugin_point_exclusive",
                "point is exclusive and has ${bindings.size} bindings: " +
                    refs.joinToString(", "),
                mapOf("refs" to refs)
            )
        }

        val ranked = Types.stableSortBy(bindings) { listOf(-it.band, it.ref) }
        return Picked(ranked[0], ranked.drop(1).map { it.ref })
    }
}
