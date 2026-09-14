// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (kotlin/src/Order.kt)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package KOTLINPACKAGE.feature.secrets.plugin

/**
 * Ordering (section 7) - one rule, one place.
 *
 * sdkgen grew two special cases in `makeOptions` (`test`, then `station`) and
 * the third was not far off. This sort is the whole replacement, and the
 * tiers are in this order for a reason:
 *
 *   1 constraints   before/after edges, by ref or by name
 *   2 bands         integer, lower first, default 0
 *   3 declaration   ties break by `pos`
 *
 * CONSTRAINTS BEAT BANDS precisely so the correct tool wins when both are
 * present. A band expresses a genuine cross-cutting layer; a constraint
 * expresses a relationship between two specific things; and a band chosen by
 * trial and error to fix an ordering bug is a bug wearing a number.
 */

/** One node of the sort. An internal shape, never a corpus value. */
data class OrderNode(val ref: String, val pos: Int, val order: Any?)

object Order {

    fun orderBand(b: OrderNode): Int =
        Types.asInt(Types.get(b.order ?: emptyMap<String, Any?>(), "band")) ?: 0

    /**
     * Was a constraint stated? An absent value and an EMPTY LIST are both
     * no-constraint - and an empty list is TRUTHY in most languages, which is
     * exactly how this class of bug survives a reading.
     */
    fun orderDeclared(spec: Any?): Boolean = when {
        null == spec -> false
        spec is List<*> -> spec.any { "" != it }
        else -> "" != spec
    }

    /**
     * One spelling or a LIST of them. A list fans out to the UNION of what
     * each names, so after: ['a','b'] means after BOTH, and the same instance
     * named twice - once by name, once by ref - is one edge.
     *
     * Matching is by REF, or by NAME across all of that definition's
     * instances (section 7) - which is the whole reason the two spellings
     * exist.
     */
    fun orderTargets(spec: Any?, nodes: List<OrderNode>): List<String> {
        val specs = if (spec is List<*>) spec else listOf(spec)
        val hit = ArrayList<String>()
        for (one in specs) {
            for (b in nodes) {
                if (hit.contains(b.ref)) continue
                if (b.ref == one || Refs.refName(b.ref) == one) hit.add(b.ref)
            }
        }
        return hit
    }

    @JvmOverloads
    fun resolveOrder(bindings: List<OrderNode>, pin: Any? = null): List<String> {
        val byref = bindings.associateBy { it.ref }

        // Constraints are edges. A constraint naming an ABSENT binding is
        // satisfied VACUOUSLY (section 7) - a plugin ordered `after: 'test'`
        // must load in a host with no test plugin. That is sdkgen's __after__
        // behaviour, kept.
        val edges = HashMap<String, MutableList<String>>()
        for (b in bindings) edges[b.ref] = ArrayList()

        for (b in bindings) {
            val block = b.order ?: emptyMap<String, Any?>()
            if (orderDeclared(Types.get(block, "after"))) {
                for (target in orderTargets(Types.get(block, "after"), bindings)) {
                    edges[target]!!.add(b.ref)
                }
            }
            if (orderDeclared(Types.get(block, "before"))) {
                edges[b.ref]!!.addAll(orderTargets(Types.get(block, "before"), bindings))
            }
        }

        val indeg = HashMap<String, Int>()
        for (b in bindings) indeg[b.ref] = 0
        for (tos in edges.values) {
            for (to in tos) indeg[to] = indeg[to]!! + 1
        }

        // Stable topological sort. Among ready nodes, band first (lower runs
        // first), then `pos` - the position the DOCUMENT visibly states, not
        // the order instances happened to load and not the incarnation `seq`.
        val out = ArrayList<String>()
        var ready = bindings.filter { 0 == indeg[it.ref] }.toMutableList()

        while (ready.isNotEmpty()) {
            ready = Types.stableSortBy(ready) { listOf(orderBand(it), it.pos) }.toMutableList()
            val next = ready.removeAt(0)
            out.add(next.ref)
            for (to in edges[next.ref]!!) {
                indeg[to] = indeg[to]!! - 1
                if (0 == indeg[to]) ready.add(byref[to]!!)
            }
        }

        if (out.size != bindings.size) {
            val stuck = bindings.filter { !out.contains(it.ref) }.map { it.ref }
            Types.fail(
                "plugin_order_cycle",
                "before/after constraints cycle: ${stuck.joinToString(" -> ")}",
                mapOf("cycle" to stuck)
            )
        }

        return applyPin(out, edges, pin)
    }

    /**
     * A PIN IS NOT A CONSTRAINT (section 7).
     *
     * Constraints and bands are negotiable by definition - they are what
     * plugins and documents say they want, and the sort's job is to satisfy
     * them all. A pin is the host stating a structural invariant of its own
     * architecture, which is a different kind of claim and must not lose a
     * tie to a document.
     *
     * So a pin PLACES the binding at the named end, and an ordering that
     * would move it away is `plugin_order_pinned` - rejected, not honoured
     * into a broken wrap.
     */
    fun applyPin(
        order: List<String>,
        edges: Map<String, MutableList<String>>,
        pin: Any?
    ): List<String> {
        if (null == pin) return order
        val out = ArrayList(order)

        // SORTED, not insertion order. A pin map is data - it can arrive from
        // a host's own construction options in any order, and two names
        // pinned to the same end are order-sensitive (`{b:'first',
        // a:'first'}` and `{a:'first', b:'first'}` give different results). A
        // Go map has no order at all, so leaving it unstated made the same
        // declaration mean different things in different ports.
        for (name in Types.keys(pin)) {
            val want = Types.get(pin, name)
            val idx = out.indexOfFirst { Refs.refName(it) == name }
            if (0 > idx) continue

            // `first`/`outermost` is index 0; `last`/`innermost` is the end.
            // Section 6.2 makes the first chain binding outermost, which is
            // why the vocabulary is positional and why the two spellings pair
            // this way.
            val wantFirst = "first" == want || "outermost" == want
            val ref = out.removeAt(idx)
            if (wantFirst) out.add(0, ref) else out.add(ref)
        }

        // Now check that the placement did not break a constraint. This is the
        // half that makes a pin a rejection rather than an override: the host
        // wins on position, but it does not get to silently discard a
        // relationship a plugin declared.
        val at = HashMap<String, Int>()
        out.forEachIndexed { i, ref -> at[ref] = i }
        for ((from, tos) in edges) {
            for (to in tos) {
                if (at[from]!! <= at[to]!!) continue
                Types.fail(
                    "plugin_order_pinned",
                    "a pin would move a binding an ordering constrains: " +
                        "$from must precede $to",
                    mapOf("before" to from, "after" to to)
                )
            }
        }
        return out
    }
}
