// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (kotlin/src/Host.kt)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package KOTLINPACKAGE.feature.secrets.plugin

import java.util.TreeMap

/**
 * The host: the lifecycle state machine (section 5), extension points
 * (section 6), and resource capture (section 8).
 *
 * TWO RULES SHAPE EVERY METHOD BELOW.
 *
 * Transitions are SEQUENTIAL (section 5.2). One at a time, in call order,
 * never interleaved; a transition triggered from inside a lifecycle callback
 * is `plugin_reentrant`. A hard rule, because it is the only way the semantics
 * can be identical in Go, in Ruby and in single-threaded JavaScript.
 *
 * Reconciliation is EAGER (section 18's portability budget). A transition
 * settles by running the state machine to a fixed point, not by suspending on
 * a promise. NOTHING HERE IS `suspend`, and that is the decision kotlin most
 * invites you to get wrong: a suspending transition would make section 5.2's
 * "one at a time, in call order" a claim about a coroutine dispatcher rather
 * than about the code.
 */

/** One registered instance. The INTERNAL record: a plugin sees `Inst`. */
class Entry(
    val ref: String,
    val def: Any?,
    var status: String,
    var pos: Int,
    val seq: Int,
    var options: MutableMap<String, Any?>,
    var order: Any?
) {
    val state: MutableMap<String, Any?> = TreeMap()
    var unmet: List<String> = emptyList()
    val scope: MutableList<() -> Unit> = ArrayList()

    /**
     * Section 11.4's ALWAYS-RELUCTANT rebinding made concrete: the provider ref
     * this instance's activation actually chose, per requirement name.
     * Re-ranking on every question silently re-points a live consumer at any
     * better newcomer, and then losing the provider it was really using does
     * not restart it.
     */
    var selected: MutableMap<String, String> = TreeMap()

    val bindings: MutableList<Binding> = ArrayList()
    val exports: MutableMap<String, Any?> = TreeMap()
    val provides: MutableList<Any?> = ArrayList()
    var inner: Host? = null
    var barred: Boolean = false
}

/**
 * What a definition's callbacks see. Deliberately not the internal record: a
 * plugin that could reach `status` could also write it.
 */
class Inst(val host: Host, private val entry: Entry) {

    val ref: String = entry.ref
    val name: String = Refs.parseRef(entry.ref)["name"] as String
    val tag: String = Refs.parseRef(entry.ref)["tag"] as String

    val options: MutableMap<String, Any?> get() = entry.options
    val state: MutableMap<String, Any?> get() = entry.state

    /**
     * Foreign resources the host did not hand out are registered explicitly
     * (section 8.3); host calls are recorded automatically.
     *
     * SYMMETRIC WITH `acquire`, and it has to be: `open` counts the resources
     * CURRENTLY HELD, so an entry that is registered and then unwound must
     * leave the count where it found it.
     */
    fun release(fn: () -> Unit) {
        // Section 8.3: "`inst.release` outside `activate` is
        // `plugin_release_scope`". `intransition` is true in `define` too, and
        // a scope entry registered there is never unwound.
        if ("activate" != host.phase) {
            Types.fail("plugin_release_scope", "release called outside activate")
        }
        var done = false
        entry.scope.add {
            if (!done) {
                done = true
                host.open--
                fn()
            }
        }
        host.open++
    }

    /**
     * The synthetic counter the driver owns, so "what is open" is data rather
     * than an assertion each port words differently.
     *
     * Returns its own release, so a plugin can hand one back early. The scope
     * still holds the entry and unwinding it twice is a no-op - releasing
     * early must not make teardown wrong.
     */
    fun acquire(): () -> Unit {
        // Section 8.1: resources are "acquired during `activate` - the scope's
        // actual job". Same reason as `release` above.
        if ("activate" != host.phase) {
            Types.fail("plugin_release_scope", "acquire called outside activate")
        }
        var done = false
        val rel = {
            if (!done) {
                done = true
                host.open--
            }
        }
        entry.scope.add(rel)
        host.open++
        return rel
    }

    /**
     * Bind into a host point. Declared in `define`; the host inserts it only
     * after `activate` returns successfully (section 8.1), which is why a
     * failing activate leaves no live binding behind.
     *
     * Section 12 has carried `plugin_bind_scope` - "binding declared outside
     * `define`" - since before anything raised it, and it was the half nobody
     * wrote: a binding added from `activate` went live without being part of
     * the loaded definition, and a deactivate/activate cycle appended it again.
     */
    @JvmOverloads
    fun bind(point: String, fn: BindingFn, band: Any? = null) {
        if ("define" != host.phase) {
            Types.fail(
                "plugin_bind_scope", "bind called outside define: $point",
                mapOf("ref" to ref, "point" to point)
            )
        }
        if (!host.hasPoint(point)) {
            Types.fail("plugin_point_unknown", "no such point: $point", mapOf("point" to point))
        }
        entry.bindings.add(Binding(ref, point, fn, Types.asInt(band) ?: 0))
    }

    /** Published for other plugins and for the application (section 11). */
    fun export(key: String, value: Any?) {
        entry.exports[key] = value
    }

    /** What this instance can do for others (section 11.1). */
    fun provides(prov: Any?) {
        entry.provides.add(prov)
    }

    /**
     * Where this binding landed (section 6.6) - the plugin-side counterpart to
     * a host pin. THE HOST DOES NOT POLICE THIS; it just makes the fact
     * available. Verification tells a plugin it was misplaced; a pin (section
     * 7) stops the misplacement from being expressible at all. The two are not
     * substitutes.
     */
    fun position(point: String): Map<String, Any?> = host.positionOf(ref, point)

    /**
     * AN INSTANCE MAY ITSELF BE A HOST (section 6.5), and THE OUTER ONE OWNS
     * THE INNER ONE'S LIFETIME. Registering the teardown in the instance scope
     * is what makes that true rather than aspirational.
     */
    @JvmOverloads
    fun nest(nestopts: Any? = null): Host {
        if (!host.intransition) {
            Types.fail("plugin_release_scope", "nest called outside a lifecycle callback")
        }
        val inner = Host(nestopts)
        // NOT counted: `open` must read the same before and after a nested host
        // is created.
        entry.scope.add { inner.close() }
        entry.inner = inner
        return inner
    }
}

class Host @JvmOverloads constructor(options: Any? = null) {

    private val opts: Any? = options ?: emptyMap<String, Any?>()
    private val dependency: String = (Types.get(options, "dependency") ?: "restart") as String

    /**
     * Set for the duration of a bulk teardown, so `held` knows this is a
     * coordinated operation rather than an ad-hoc deactivation.
     */
    private var coordinated = false

    val catalog: Catalog = (Types.get(options, "catalog") ?: Catalog()) as Catalog
    private val reserved: List<*> = (Types.get(options, "reserved") ?: emptyList<Any?>()) as List<*>
    private val points: Map<*, *> =
        (Types.get(options, "points") ?: emptyMap<String, Any?>()) as Map<*, *>

    private val inst = TreeMap<String, Entry>()
    private val log = ArrayList<String>()

    /**
     * Section 14: the lifecycle event record. `seq` distinguishes ONE
     * INCARNATION of stripe$test from the next, which is the whole reason it is
     * not `pos` (section 4 rule 4).
     */
    private val events = ArrayList<Any?>()
    private var seqn = 0
    var open = 0
    var intransition = false

    /**
     * WHICH callback is running, not merely that one is. Section 8.1 puts
     * resource capture in `activate` and 8.3 says `release` outside `activate`
     * is `plugin_release_scope` - and `intransition` alone cannot tell
     * `activate` from `define`, so it admitted an acquire in `define` whose
     * scope `unload` would never unwind.
     */
    var phase: String? = null

    fun hasPoint(name: String): Boolean = points.containsKey(name)

    // --- observation ----------------------------------------------------

    /**
     * Introspection NEVER advances the state (section 5.2). A status page must
     * not be a way to accidentally import twenty packages.
     */
    fun list(): Map<String, Any?> {
        val out = TreeMap<String, Any?>()
        for ((ref, e) in inst) out[ref] = e.status
        return out
    }

    fun instance(ref: Any?): Entry? = inst[Refs.canonRef(ref)]

    fun trace(): List<Any?> = ArrayList(events)

    @JvmOverloads
    fun observable(result: Any? = null): Map<String, Any?> {
        val out = TreeMap<String, Any?>()
        out["status"] = list()
        out["open"] = open.toDouble()
        out["log"] = ArrayList(log)
        out["result"] = result
        return out
    }

    private fun refs(): List<String> = inst.keys.toList()

    // --- the state machine -----------------------------------------------

    private fun guard() {
        if (!intransition) return
        Types.fail(
            "plugin_reentrant",
            "transition attempted from inside a lifecycle callback"
        )
    }

    private fun need(ref: Any?): Entry {
        val rf = Refs.canonRef(ref)
        return inst[rf]
            ?: Types.fail("plugin_not_loaded", "no such instance: $rf", mapOf("ref" to rf))
    }

    private fun checkReserved(ref: String) {
        if (!reserved.contains(Refs.refName(ref))) return
        Types.fail(
            "plugin_ref_reserved", "ref is reserved by the host: $ref",
            mapOf("ref" to ref)
        )
    }

    private fun run(entry: Entry, callback: String, at: String) {
        val fn = Types.get(entry.def, callback)
        log.add("${entry.ref}:$at")
        val event = TreeMap<String, Any?>()
        event["ref"] = entry.ref
        event["event"] = at
        event["seq"] = entry.seq.toDouble()
        event["status"] = entry.status
        events.add(event)
        if (fn !is Function1<*, *>) return

        intransition = true
        phase = at
        try {
            @Suppress("UNCHECKED_CAST")
            (fn as (Inst) -> Any?)(Inst(this, entry))
        } catch (e: Exception) {
            // Section 12: `plugin_define_failed` and its three siblings are "a
            // callback raised; wraps the cause". AN ERROR THAT ALREADY CARRIES
            // A CODE KEEPS IT - the code is the error's identity, and a plugin
            // raising `store_unreachable` must not have it rewritten. Only a
            // code-less error is wrapped.
            if ("" != Types.codeOf(e)) throw e
            Types.fail(
                "plugin_${at}_failed",
                "${entry.ref} raised in $at: ${Types.messageOf(e)}",
                mapOf("ref" to entry.ref, "cause" to Types.messageOf(e))
            )
        } finally {
            intransition = false
            phase = null
        }
    }

    /**
     * AUTO-TAGGING IS EXPLICIT (section 4 rule 3). `declare("stripe", {"tag":
     * "?"})` assigns the LOWEST UNUSED POSITIVE INTEGER tag and returns the
     * assigned pair. Without `"?"`, a collision is an error.
     */
    private fun autotag(name: String): String {
        var n = 1
        while (true) {
            val cand = Refs.formatRef(name, n.toString())
            if (!inst.containsKey(cand)) return cand
            n++
        }
    }

    @JvmOverloads
    fun declare(ref: Any?, spec: Any? = null): Entry {
        val given = spec ?: emptyMap<String, Any?>()
        val named = if ("?" == Types.get(given, "tag")) {
            autotag(Refs.refName(Refs.canonRef(ref)))
        } else {
            ref
        }
        val rf = Refs.canonRef(named)
        if (!Types.truthy(Types.get(given, "hostowned"))) checkReserved(rf)

        val defname = (Types.get(given, "definition") ?: Refs.refName(rf)) as String
        val definition = catalog.get(defname)
            ?: Types.fail(
                "plugin_unknown_definition", "not in catalog: $defname",
                mapOf("name" to defname)
            )

        val existing = inst[rf]
        if (null != existing) {
            // Section 4 rule 1: a pair addresses at most one instance.
            // Re-declaring the SAME definition is the idempotent case; a
            // different one is a duplicate, not a silent overwrite (seneca) and
            // not an impossibility (sdkgen).
            if (Types.get(existing.def, "name") != Types.get(definition, "name")) {
                Types.fail(
                    "plugin_ref_duplicate", "instance already declared: $rf",
                    mapOf("ref" to rf)
                )
            }
            return existing
        }

        val pos = Types.asInt(Types.get(given, "pos"))
        val options = TreeMap<String, Any?>()
        val declared = Types.get(given, "options")
        for (k in Types.keys(declared)) options[k] = Types.get(declared, k)

        val entry = Entry(
            rf, definition, "declared",
            pos ?: inst.size, seqn, options, Types.get(given, "order")
        )
        seqn++
        inst[rf] = entry
        return entry
    }

    /**
     * Section 9.1: a host that reserves a name MUST still be able to declare
     * the instance it reserved - "The host declares those instances itself,
     * after the user merge, and always wins."
     *
     * THE BOUNDARY IS BY METHOD, NOT BY CALLER, and that is a real limit: no
     * language here can tell the embedding host from a plugin holding the same
     * host object. What reservation protects is CONFIGURATION - documents,
     * overlays, `VOXGIG_PLUGIN_*`, construction options and ordinary
     * declare/load/options - and all of that still checks.
     */
    @JvmOverloads
    fun hostdeclare(ref: Any?, spec: Any? = null): Entry {
        guard()
        val merged = TreeMap<String, Any?>()
        for (k in Types.keys(spec)) merged[k] = Types.get(spec, k)
        merged["hostowned"] = true
        return declare(ref, merged)
    }

    @JvmOverloads
    fun load(ref: Any?, spec: Any? = null): Entry {
        guard()
        val entry = declare(ref, spec)
        if ("declared" != entry.status) return entry // idempotent trivially

        val options = Types.get(spec, "options")
        if (null != options) {
            val fresh = TreeMap<String, Any?>()
            for (k in Types.keys(options)) fresh[k] = Types.get(options, k)
            entry.options = fresh
        }
        try {
            run(entry, "define", "define")
        } catch (e: Exception) {
            entry.status = "failed"
            throw e
        }
        entry.status = "loaded"

        // AT LOAD, and before anything runs: a cycle through restart-causing
        // requirements does not settle, and the only safe time to report a
        // non-terminating reconcile is before it starts (section 11.3).
        // `provides` is populated by `define`, which has just run, so this is
        // the first moment the graph is complete.
        try {
            Depend.checkCycle(graphNodes())
        } catch (e: Exception) {
            entry.status = "failed"
            throw e
        }
        return entry
    }

    /** The requirement graph as plain data, for the pure detector. */
    private fun graphNodes(): List<GraphNode> = refs().map { rf ->
        GraphNode(
            rf,
            inst[rf]!!.provides.map { Types.get(it, "name") as String },
            Depend.requirements(inst[rf]!!.options)
        )
    }

    fun activate(ref: Any?): Entry {
        guard()
        val entry = need(ref)
        if ("live" == entry.status) return entry // no-op returning success

        if ("failed" == entry.status) {
            Types.fail(
                "plugin_bad_state", "instance has failed: ${entry.ref}",
                mapOf("ref" to entry.ref)
            )
        }
        // Section 9.6: `active: false` bars the instance from running, and the
        // bar is on the INSTANCE rather than on the apply that set it. `ready`
        // reaches this through `activate`, so one guard covers both verbs the
        // design names.
        if (entry.barred) {
            Types.fail(
                "plugin_inactive", "instance is barred by active: false: ${entry.ref}",
                mapOf("ref" to entry.ref)
            )
        }
        if ("declared" == entry.status) load(entry.ref)

        // A declared requirement that is not live means `pending`: activation
        // is a STANDING REQUEST, not a one-shot event.
        val unmet = unmetOf(entry)
        if (unmet.isNotEmpty()) {
            entry.unmet = unmet
            entry.status = "pending"
            return entry
        }

        try {
            run(entry, "activate", "activate")
        } catch (e: Exception) {
            // Unwind whatever the partial activation captured, in reverse.
            unwind(entry)
            entry.status = "failed"
            throw e
        }
        // Section 11.4: THE SELECTION IS MADE HERE, once, and remembered. Every
        // later question - the cascade, `hold`, `unmet` - reads it back rather
        // than re-ranking, which is what "always-reluctant" means.
        for (req in Depend.requirements(entry.options)) chosen(entry, req, true)
        entry.status = "live"
        reconcile()
        return entry
    }

    fun deactivate(ref: Any?): Entry {
        guard()
        val entry = need(ref)
        if ("loaded" == entry.status || "declared" == entry.status) return entry

        // Section 5.2: `unload` is THE ONLY TRANSITION OUT OF `failed`.
        if ("failed" == entry.status) {
            Types.fail(
                "plugin_bad_state", "instance has failed: ${entry.ref}",
                mapOf("ref" to entry.ref)
            )
        }

        if ("pending" == entry.status) {
            // DEACTIVATING A PENDING INSTANCE RUNS NO CALLBACK (section 5.2).
            // It never reached activate, so it holds no scope and no live
            // bindings; running the definition's deactivate there would be
            // teardown without matching setup, which plugins are not written to
            // survive and which could fail an instance that had done nothing
            // wrong. It cannot fail.
            entry.status = "loaded"
            entry.unmet = emptyList()
            return entry
        }

        held(entry)
        cascade(entry, HashSet())
        teardown(entry)
        entry.status = "loaded"
        reconcile()
        return entry
    }

    /** The live half of leaving `live`: the callback, then the scope. */
    private fun teardown(entry: Entry) {
        try {
            run(entry, "deactivate", "deactivate")
        } catch (e: Exception) {
            unwind(entry)
            entry.status = "failed"
            throw e
        }
        releaseCheck(entry, unwind(entry))
    }

    fun unload(ref: Any?) {
        guard()
        val entry = need(ref)
        if ("live" == entry.status || "pending" == entry.status) {
            // Section 5.2: ANY failure during a transition lands the instance
            // in `failed`, with the scope STILL FULLY UNWOUND - and the
            // instance STAYS REGISTERED, because `failed` is a state an
            // operator has to be able to see.
            if ("live" == entry.status) {
                held(entry)
                cascade(entry, HashSet())
                teardown(entry)
            }
            entry.status = "loaded"
        }
        if ("loaded" == entry.status || "failed" == entry.status) {
            try {
                run(entry, "close", "close")
            } finally {
                inst.remove(entry.ref)
            }
            return
        }
        inst.remove(entry.ref)
    }

    /** Runs the whole forward path in one call (section 5.1). */
    fun ready(ref: Any?): Entry {
        guard()
        val rf = Refs.canonRef(ref)
        if (!inst.containsKey(rf)) declare(rf)
        if ("declared" == inst[rf]!!.status) load(rf)
        return activate(rf)
    }

    /**
     * Bindings go live only when activation succeeds (section 8.1), so the
     * teardown is the exact inverse: reverse order, always.
     *
     * Returns the errors the scope raised. Section 8.3: "A failing release does
     * not stop the rest. Every entry runs, in reverse order, whatever any of
     * them does; the errors are collected and raised as one
     * `plugin_release_failed`."
     *
     * A selection belongs to ONE activation (section 11.4). Leaving `live` by
     * any door drops it, so the next activation ranks afresh - keeping it would
     * make a consumer prefer a provider it never actually ran against.
     */
    private fun unwind(entry: Entry): List<Throwable> {
        entry.selected = TreeMap()
        val errors = ArrayList<Throwable>()
        for (i in entry.scope.indices.reversed()) {
            try {
                entry.scope[i]()
            } catch (e: Exception) {
                errors.add(e)
            }
        }
        entry.scope.clear()
        return errors
    }

    /**
     * Section 8.3: "A failed release ends the instance in `failed`, exactly as
     * a failed callback does (5.2) - a release that raised may have leaked, and
     * an instance that may be holding resources it cannot account for must not
     * be reactivated."
     */
    private fun releaseCheck(entry: Entry, errors: List<Throwable>) {
        if (errors.isEmpty()) return
        entry.status = "failed"
        val causes = errors.map { Types.messageOf(it) }
        Types.fail(
            "plugin_release_failed",
            "release failed for ${entry.ref}: ${causes.joinToString("; ")}",
            mapOf("ref" to entry.ref, "cause" to causes)
        )
    }

    /**
     * A REQUIREMENT IS ON A CAPABILITY, not on a ref (section 11.1). A bare
     * string is shorthand for `{name}`. A ref satisfies too, because a host
     * that genuinely needs a specific instance should not have to invent a
     * capability for it.
     */
    private fun unmetOf(entry: Entry): List<String> =
        Depend.requirements(entry.options)
            .filter { Depend.gatesActivation(it) }
            .filter { providersOf(it).isEmpty() }
            .map { Types.get(it, "name") as String }

    /**
     * Section 11.4's always-reluctant selection, and the ONE place a provider
     * is picked for a live instance. If this instance already selected a
     * provider for `req` and that provider is STILL a candidate, it keeps it -
     * a better-ranked newcomer does not take it.
     *
     * `remember` is false for the questions asked ABOUT an instance rather than
     * BY it: introspection must not create a binding.
     */
    private fun chosen(entry: Entry, req: Any?, remember: Boolean): String? {
        val cands = providersOf(req)
        if (cands.isEmpty()) return null
        val name = Types.get(req, "name") as String
        val held = entry.selected[name]
        if (null != held && cands.any { Types.get(it, "ref") == held }) return held
        val pick = Types.get(cands[0], "ref") as String
        if (remember) entry.selected[name] = pick
        return pick
    }

    /**
     * The instances currently SELECTED for this one's restart-causing
     * requirements. A BINDING IS TO AN INSTANCE, not to a capability (section
     * 11.1): the selected one going away restarts a `static` consumer even
     * though a survivor is available.
     */
    private fun boundProviders(entry: Entry): List<String> {
        val out = ArrayList<String>()
        for (req in Depend.requirements(entry.options)) {
            if (!Depend.restartsOnLoss(req)) continue
            val ref = chosen(entry, req, false)
            if (null != ref && !out.contains(ref)) out.add(ref)
        }
        return out
    }

    /**
     * Live instances whose selected provider is `ref` and which would be
     * restarted by losing it.
     */
    private fun consumersOf(ref: String): List<String> = refs().filter {
        it != ref && "live" == inst[it]!!.status && boundProviders(inst[it]!!).contains(ref)
    }

    /**
     * Section 11.3's `hold` asks a DIFFERENT question from the cascade, and
     * reading it off `consumersOf` answered the cascade's.
     *
     * The cascade wants the edges that RESTART - mandatory-static and
     * optional-static - because a restart is what it performs. `hold` says
     * "deactivating a REQUIRED instance is `plugin_dependency_held`", and
     * required is cardinality: `gatesActivation`, not `restartsOnLoss`. The two
     * sets differ in both directions and each difference was a real bug.
     *
     * A MANDATORY-DYNAMIC consumer was excluded, so the strictest policy let a
     * provider go that a live consumer could not do without - `dynamic`
     * promises survival of a SWAP, and under `hold` there is no swap, so the
     * consumer falls back to `pending`.
     *
     * An OPTIONAL-STATIC consumer was included, so `hold` refused a
     * deactivation on behalf of an instance that had said in writing it does
     * not need the thing.
     */
    private fun holdersOf(ref: String): List<String> = refs().filter { rf ->
        val c = inst[rf]!!
        if (rf == ref || "live" != c.status) {
            false
        } else {
            Depend.requirements(c.options).any {
                Depend.gatesActivation(it) && ref == chosen(c, it, false)
            }
        }
    }

    private fun providersOf(req: Any?): List<Any?> {
        val cands = ArrayList<Any?>()
        val name = Types.get(req, "name")
        val want = Refs.canon(name)
        for (ref in refs()) {
            val target = inst[ref]!!
            if ("live" != target.status) continue
            // A ref satisfies directly.
            if (ref == want) {
                val c = TreeMap<String, Any?>()
                c["ref"] = ref
                c["pos"] = target.pos.toDouble()
                c["provides"] = mapOf("name" to name)
                cands.add(c)
                continue
            }
            for (prov in target.provides) {
                if (Types.get(prov, "name") != name) continue
                val c = TreeMap<String, Any?>()
                c["ref"] = ref
                c["pos"] = target.pos.toDouble()
                c["provides"] = prov
                cands.add(c)
            }
        }
        return Capability.resolveCapability(req, cands)
    }

    /**
     * CONSUMERS GO DOWN FIRST, NOT AFTERWARDS (section 11.3).
     *
     * The cascade is part of the provider's own deactivation and runs BEFORE
     * the provider's `deactivate` callback and scope unwind, so a consumer's
     * teardown can still call the thing it depends on - flushing a buffer to
     * the store it is about to lose is exactly what a `deactivate` callback is
     * for, and a cascade that fired after the provider was already gone would
     * make that impossible.
     */
    private fun cascade(provider: Entry, seen: MutableSet<String>) {
        if (seen.contains(provider.ref)) return
        seen.add(provider.ref)

        for (rf in consumersOf(provider.ref)) {
            val consumer = inst[rf]!!
            if ("live" != consumer.status) continue
            cascade(consumer, seen) // deepest-first
            demote(consumer)
        }
    }

    /**
     * Leaving `live` for `pending` - or for `failed`, because section 5.2 says
     * ANY failure during a transition lands the instance there. Marking it
     * `pending` handed it straight back to `reconcile`, which would activate it
     * again the moment the provider returned.
     */
    private fun demote(entry: Entry) {
        var bad = false
        try {
            run(entry, "deactivate", "deactivate")
        } catch (e: Exception) {
            bad = true
        }
        val errors = unwind(entry)
        if (bad || errors.isNotEmpty()) {
            entry.status = "failed"
            return
        }
        entry.status = "pending"
        entry.unmet = unmetOf(entry)
    }

    /**
     * The hold check is A GUARD ON AD-HOC DEACTIVATION, NOT ON COORDINATED
     * TEARDOWN. In a bulk operation that is removing the holders too - `close`,
     * or an `apply` plan whose own steps deactivate them - it is suspended for
     * exactly those holders, and the teardown still runs consumers before
     * providers.
     */
    private fun held(entry: Entry) {
        if ("hold" != dependency || coordinated) return
        val holders = holdersOf(entry.ref)
        if (holders.isEmpty()) return
        Types.fail(
            "plugin_dependency_held",
            "instance is required by live consumers: ${entry.ref}",
            mapOf("ref" to entry.ref, "holders" to holders)
        )
    }

    /**
     * EAGER reconciliation: run to a fixed point rather than scheduling.
     *
     * Two directions, and both are the reason `pending` exists. Activation is a
     * STANDING REQUEST, not a one-shot event.
     */
    private fun reconcile() {
        var moved = true
        var rounds = 0
        while (moved) {
            moved = false
            rounds++
            if (1000 < rounds) break

            // Losses first, so a cascade settles in one pass rather than
            // alternating with re-activations.
            for (rf in refs()) {
                val entry = inst[rf] ?: continue
                if ("live" != entry.status) continue
                // POLICY IS PER REQUIREMENT, not per instance (section 11.3). A
                // `dynamic` requirement whose provider is gone leaves the
                // consumer LIVE and notified.
                val lost = Depend.requirements(entry.options)
                    .filter { Depend.gatesActivation(it) }
                    .filter { providersOf(it).isEmpty() }
                if (lost.isEmpty()) continue
                if (!lost.any { Depend.restartsOnLoss(it) }) continue
                demote(entry)
                moved = true
            }

            for (rf in refs()) {
                val entry = inst[rf] ?: continue
                if ("pending" != entry.status) continue
                if (unmetOf(entry).isNotEmpty()) continue
                try {
                    run(entry, "activate", "activate")
                    entry.status = "live"
                    entry.unmet = emptyList()
                } catch (e: Exception) {
                    unwind(entry)
                    entry.status = "failed"
                }
                moved = true
            }
        }
    }

    // --- ordering ---------------------------------------------------------

    @JvmOverloads
    fun order(point: String? = null): List<String> {
        // Sorted by declaration SEQUENCE, which is what makes the section 7
        // sort's fall-through deterministic in a language whose maps have no
        // insertion order. Section 7 breaks ties by `pos`; two instances CAN
        // share one - `declare` defaults `pos` to the registry size, so an
        // unload followed by a fresh declare reuses a surviving instance's -
        // and past that this was falling through to map order. `seq` is that
        // order, made explicit.
        val bindings = refs()
            .filter { "live" == inst[it]!!.status }
            .sortedBy { inst[it]!!.seq }
            .map { OrderNode(it, inst[it]!!.pos, inst[it]!!.order) }
        val spec = if (null == point) null else points[point]
        return Order.resolveOrder(bindings, if (null == spec) null else Types.get(spec, "pin"))
    }

    // --- points -----------------------------------------------------------

    /**
     * Live bindings on a point, in resolved order. Recomputed on any change to
     * the live set (section 7) rather than cached at startup - the bug a host
     * discovers only when something deactivates in production.
     */
    private fun bound(point: String): List<Binding> {
        val out = ArrayList<Binding>()
        for (ref in order(point)) {
            val entry = inst[ref]!!
            // The band is the INSTANCE's ordering block (section 7), stamped by
            // the host. A plugin passing its own would be ranking itself above
            // the order its document declared.
            val band = Types.asInt(
                Types.get(entry.order ?: emptyMap<String, Any?>(), "band")
            ) ?: 0
            for (b in entry.bindings) {
                if (b.point == point) out.add(b.copy(band = band))
            }
        }
        return out
    }

    private fun pointSpec(point: String, want: String): Any? {
        val spec = points[point]
            ?: Types.fail(
                "plugin_point_unknown", "no such point: $point",
                mapOf("point" to point)
            )
        val kind = Types.get(spec, "kind")
        if ("hook" == want) {
            // A point with no declared kind is a hook, which is what makes `{}`
            // the minimal point declaration.
            if (null != kind && "hook" != kind) {
                Types.fail(
                    "plugin_point_kind", "point is not a hook: $point",
                    mapOf("point" to point, "kind" to kind)
                )
            }
            return spec
        }
        if (kind != want) {
            Types.fail(
                "plugin_point_kind", "point is not a $want: $point",
                mapOf("point" to point, "kind" to kind)
            )
        }
        return spec
    }

    @JvmOverloads
    fun emit(point: String, arg: Any? = null): Any? {
        val spec = pointSpec(point, "hook")
        return Point.pointEmit(bound(point), (Types.get(spec, "mode") ?: "emit") as String, arg)
    }

    @JvmOverloads
    fun call(point: String, arg: Any? = null): Any? {
        val spec = pointSpec(point, "chain")
        @Suppress("UNCHECKED_CAST")
        val base = (Types.get(spec, "base") ?: { a: Any? -> a }) as (Any?) -> Any?
        return Point.compose(bound(point), base)(arg)
    }

    @JvmOverloads
    fun provider(point: String, arg: Any? = null): Any? {
        val spec = pointSpec(point, "provider")
        val pick = Point.pointProvider(bound(point), spec)
        val winner = pick.winner ?: return Types.get(spec, "default")
        return winner.fn(null, arg)
    }

    /** The losers are VISIBLE rather than silently ignored (section 6.3). */
    fun shadowed(point: String): List<String> {
        val spec = points[point] ?: return emptyList()
        return Point.pointProvider(bound(point), spec).shadowed
    }

    fun exports(spec: String): Any? {
        val all = ArrayList<Export.Exported>()
        for (ref in refs()) {
            val entry = inst[ref]!!
            // Exports of a `loaded` (not live) instance are VISIBLE (11).
            if ("declared" == entry.status || "failed" == entry.status) continue
            for (k in Types.keys(entry.exports)) {
                all.add(Export.Exported(ref, k, entry.exports[k]))
            }
        }
        return Export.resolveExport(spec, all)
    }

    /** The live providers of a capability, best-first (section 11.1). */
    fun capability(name: String): List<String> {
        val cands = ArrayList<Any?>()
        for (ref in refs()) {
            val entry = inst[ref]!!
            if ("live" != entry.status) continue
            for (prov in entry.provides) {
                if (Types.get(prov, "name") != name) continue
                val c = TreeMap<String, Any?>()
                c["ref"] = ref
                c["pos"] = entry.pos.toDouble()
                c["provides"] = prov
                cands.add(c)
            }
        }
        return Capability.resolveCapability(mapOf("name" to name), cands)
            .map { Types.get(it, "ref") as String }
    }

    // --- documents ---------------------------------------------------------

    private fun shapeOf(ref: String): Any? =
        Types.get(catalog.get(Refs.refName(ref)), "shape")

    /**
     * Section 9.6: "load what is missing, UNLOAD WHAT IS GONE, patch what
     * changed, and move activation state to match", with the stated ordering -
     * "deactivations and unloads first (reverse load order), then loads, then
     * activations in load order".
     *
     * FOUR PHASES, NOT ONE INTERLEAVED LOOP. An earlier draft walked the
     * document once, which never looked at instances the new document had
     * DROPPED - so an integration removed from a config reload stayed live with
     * its bindings and resources.
     */
    @JvmOverloads
    fun apply(doc: Any?, profile: Any? = null) {
        guard()
        val useProfile = profile ?: Types.get(opts, "profile")
        val norm = Config.normalizeConfig(
            mapOf(
                "doc" to doc, "profile" to useProfile,
                "keys" to Types.get(opts, "keys"), "reserved" to reserved
            )
        )

        @Suppress("UNCHECKED_CAST")
        val want = norm["order"] as List<String>
        val defaults = Types.get(opts, "defaults") ?: emptyMap<String, Any?>()
        val optionsof = TreeMap<String, Map<String, Any?>>()
        for (ref in want) {
            optionsof[ref] = Config.resolveOptions(
                mapOf(
                    "ref" to ref, "doc" to doc, "profile" to useProfile,
                    "shape" to shapeOf(ref),
                    "hostdefaults" to Types.get(defaults, Refs.refName(ref))
                )
            )
        }

        // Should this ref be LIVE after the apply? False for a ref the document
        // declares lazy or inactive AND for one it does not name at all - which
        // is what makes "unload what is gone" and "unload what was toggled off"
        // one rule rather than two.
        val wantlive = { ref: String ->
            val ent = Types.get(norm["instance"], ref)
            null != ent && Types.truthy(Types.get(ent, "active")) &&
                "eager" == Types.get(ent, "start")
        }

        // --- phase 1: deactivations and unloads, REVERSE load order ---------
        val drop = refs().filter { "declared" != inst[it]!!.status && !wantlive(it) }
        // Highest `pos` first, ref-descending for a tie, so a consumer declared
        // after its provider goes down first.
        val ordered = drop.sortedWith(Comparator { a: String, b: String ->
            val pa = inst[a]!!.pos
            val pb = inst[b]!!.pos
            if (pa == pb) b.compareTo(a) else pb.compareTo(pa)
        })
        for (ref in ordered) unload(ref)

        // --- phase 2: declare and patch EVERYTHING, in load order -----------
        for (ref in want) {
            val ent = Types.get(norm["instance"], ref)
            declare(
                ref,
                mapOf(
                    "options" to optionsof[ref],
                    "order" to Types.get(ent, "order"),
                    "pos" to Types.get(ent, "pos")
                )
            )
            val entry = inst[ref]!!
            // The bar is REASSERTED ON EVERY APPLY, in both directions - a
            // document that turns the instance back on clears it, which is the
            // whole point of a config switch.
            entry.barred = !Types.truthy(Types.get(ent, "active"))
            // REFILL rather than REBIND. A definition's callbacks close over the
            // options map they were handed at `define`.
            entry.options.clear()
            entry.options.putAll(optionsof[ref]!!)
            entry.order = Types.get(ent, "order")
            entry.pos = Types.asInt(Types.get(ent, "pos"))!!
        }

        // --- phase 3: loads, in load order ----------------------------------
        // ONLY THE EAGER, ACTIVE ONES: "a document of twenty lazy instances is
        // twenty map entries and no executed code" (9.6).
        for (ref in want) if (wantlive(ref)) load(ref)

        // --- phase 4: activations, in load order ----------------------------
        for (ref in want) if (wantlive(ref)) activate(ref)
    }

    fun options(ref: Any?, patch: Any?) {
        guard()
        val entry = need(ref)
        val previous = TreeMap<String, Any?>()
        previous.putAll(entry.options)
        val merged = TreeMap<String, Any?>()
        merged.putAll(previous)
        for (k in Types.keys(patch)) merged[k] = Types.get(patch, k)

        val resolved = Config.resolveOptions(
            mapOf(
                "ref" to entry.ref, "shape" to shapeOf(entry.ref),
                "doc" to emptyMap<String, Any?>(), "patch" to merged
            )
        )
        entry.options.clear()
        entry.options.putAll(resolved)
        if ("live" != entry.status) return

        val reconfigure = Types.get(entry.def, "reconfigure")
        if (reconfigure is Function3<*, *, *, *>) {
            intransition = true
            try {
                @Suppress("UNCHECKED_CAST")
                (reconfigure as (Inst, Any?, Any?) -> Any?)(
                    Inst(this, entry), entry.options, previous
                )
            } finally {
                intransition = false
            }
        } else {
            // Always correct and sometimes expensive; `reconfigure` exists to
            // make the common case cheap (section 9.4).
            deactivate(entry.ref)
            activate(entry.ref)
        }
    }

    fun close() {
        // A bulk teardown removing the holders too, so `hold` is suspended for
        // exactly those holders (section 11.3) - while the consumers-first
        // cascade still runs, which is the half that matters.
        coordinated = true
        try {
            // `asReversed()` and not `reversed()`: kotlinc 1.3 resolves the
            // latter to the JDK's `List.reversed` default method on a newer
            // JDK and warns that it may not survive, which is a warning this
            // port promotes to an error.
            for (rf in refs().asReversed()) unload(rf)
        } finally {
            coordinated = false
        }
    }

    /**
     * The same record section 6.6 gives a plugin about itself, reachable from
     * outside for the corpus.
     */
    fun positionOf(ref: Any?, point: String): Map<String, Any?> {
        val entry = inst[Refs.canon(ref)]
            ?: Types.fail("plugin_not_loaded", "no such instance: $ref", mapOf("ref" to ref))
        val ranked = order(point)
        val index = ranked.indexOf(entry.ref)
        val out = TreeMap<String, Any?>()
        out["index"] = index.toDouble()
        out["count"] = ranked.size.toDouble()
        // Section 6.2 composes b1(b2(b3(base))) with the FIRST binding
        // OUTERMOST, so these are not index 0 and index count-1 the other way
        // round.
        out["outermost"] = 0 == index
        out["innermost"] = index == ranked.size - 1
        return out
    }

    fun define(definition: Any?) = catalog.add(definition)
}
