// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (csharp/src/Host.cs)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
using System;
using System.Collections.Generic;

namespace Voxgig.Plugin
{
    /// <summary>
    /// The host: the lifecycle state machine (§5), extension points (§6),
    /// and resource capture (§8).
    ///
    /// <para>TWO RULES SHAPE EVERY METHOD BELOW.</para>
    ///
    /// <para>Transitions are SEQUENTIAL (§5.2). One at a time, in call
    /// order, never interleaved; a transition triggered from inside a
    /// lifecycle callback is <c>plugin_reentrant</c>. A hard rule, because
    /// it is the only way the semantics can be identical in Go, in Csharp
    /// and in single-threaded JavaScript.</para>
    ///
    /// <para>Reconciliation is EAGER (§18's portability budget). A
    /// transition settles by running the state machine to a fixed point,
    /// not by suspending on a promise - which is also why nothing here is
    /// <c>async</c>: a <c>Task</c>-returning callback would hand the host
    /// something it is specified not to await.</para>
    ///
    /// <para>THIS HOST IS NOT THREAD-SAFE, and that is the model rather
    /// than an omission: §5.2 makes transitions sequential, and a lock
    /// would only turn a concurrent call into a slow one that still
    /// violated the ordering the corpus pins.</para>
    /// </summary>
    public sealed class Host
    {
        private readonly object opts;
        private readonly string dependency;
        private readonly object reserved;
        private readonly object points;
        private Catalog catalog = new Catalog();

        private readonly SortedDictionary<string, Entry> inst =
            new SortedDictionary<string, Entry>(StringComparer.Ordinal);

        private readonly List<object> log = new List<object>();

        /// §14: the lifecycle event record. <c>seq</c> distinguishes ONE
        /// INCARNATION of stripe$test from the next, which is the whole
        /// reason it is not <c>pos</c> (§4 rule 4).
        private readonly List<object> events = new List<object>();

        private double seqn;
        private long open;
        private bool transition;

        /// <summary>
        /// WHICH callback is running, not merely that one is. §8.1 puts
        /// resource capture in <c>activate</c> and 8.3 says
        /// <c>release</c> outside <c>activate</c> is
        /// <c>plugin_release_scope</c> - and a bare flag cannot tell
        /// <c>activate</c> from <c>define</c>.
        /// </summary>
        private string phase = "";

        /// Set for the duration of a bulk teardown, so <c>Held</c> knows
        /// this is a coordinated operation rather than an ad-hoc
        /// deactivation.
        private bool coordinated;

        public Host(object options)
        {
            opts = null == options ? Types.NewMap() : options;
            dependency = Types.Str(Types.Get(opts, "dependency")) ?? "restart";
            reserved = Types.Get(opts, "reserved");
            points = Types.Get(opts, "points");
        }

        public static Host MakeHost(object options)
        {
            return new Host(options);
        }

        public void Define(Definition definition)
        {
            catalog.Add(definition);
        }

        public Catalog CatalogRef()
        {
            return catalog;
        }

        public void CatalogRef(Catalog replacement)
        {
            catalog = replacement;
        }

        public bool InTransition()
        {
            return transition;
        }

        public string Phase()
        {
            return phase;
        }

        public bool HasPoint(string name)
        {
            return Types.Has(points, name);
        }

        public void OpenInc()
        {
            open++;
        }

        public void OpenDec()
        {
            open--;
        }

        // --- observation ------------------------------------------------

        /// Introspection NEVER advances the state (§5.2). A status page
        /// must not be a way to accidentally import twenty packages.
        public SortedDictionary<string, object> List()
        {
            var out_ = Types.NewMap();
            foreach (var pair in inst)
            {
                out_[pair.Key] = pair.Value.Status;
            }
            return out_;
        }

        /// <summary>
        /// The instance record, or null when nothing is registered under
        /// that ref. THE REF IS VALIDATED, not merely canonicalized:
        /// looking an instance up by <c>"bad name"</c> is
        /// <c>plugin_bad_name</c>, not a quiet miss.
        /// </summary>
        public Entry Instance(object eref)
        {
            return inst.TryGetValue(Refs.CanonRef(eref), out var e) ? e : null;
        }

        public List<object> Trace()
        {
            return new List<object>(events);
        }

        public SortedDictionary<string, object> Observable(object result)
        {
            var out_ = Types.NewMap();
            out_["status"] = List();
            out_["open"] = (double)open;
            out_["log"] = new List<object>(log);
            out_["result"] = result;
            return out_;
        }

        // --- the state machine ------------------------------------------

        private void Guard()
        {
            if (!transition)
            {
                return;
            }
            Types.Fail("plugin_reentrant",
                       "transition attempted from inside a lifecycle callback", null);
        }

        private Entry Need(object eref)
        {
            var r = Refs.CanonRef(eref);
            if (!inst.TryGetValue(r, out var entry))
            {
                Types.Fail("plugin_not_loaded", "no such instance: " + r,
                           Types.Details("ref", r));
            }
            return entry;
        }

        private void CheckReserved(string eref)
        {
            var list = Types.List(reserved);
            if (null == list || 0 == list.Count)
            {
                return;
            }
            if (!list.Contains(Refs.RefName(eref)))
            {
                return;
            }
            Types.Fail("plugin_ref_reserved", "ref is reserved by the host: " + eref,
                       Types.Details("ref", eref));
        }

        private void Run(Entry entry, string callback, string at)
        {
            log.Add(entry.Ref + ":" + at);
            var ev = Types.NewMap();
            ev["ref"] = entry.Ref;
            ev["event"] = at;
            ev["seq"] = entry.Seq;
            ev["status"] = entry.Status;
            events.Add(ev);

            var func = entry.Def.CallbackFor(callback);
            if (null == func)
            {
                return;
            }

            transition = true;
            phase = at;
            try
            {
                func(new Inst(this, entry));
            }
            catch (Exception e)
            {
                // §12: `plugin_define_failed` and its three siblings are "a
                // callback raised; wraps the cause". AN ERROR THAT ALREADY
                // CARRIES A CODE KEEPS IT - the code is the error's
                // identity, and a plugin raising `store_unreachable` must
                // not have it rewritten. Only a code-less error is wrapped.
                if (0 != Types.CodeOf(e).Length)
                {
                    throw;
                }
                Types.Fail("plugin_" + at + "_failed",
                           entry.Ref + " raised in " + at + ": " + e.Message,
                           Types.Details("ref", entry.Ref, "cause", e.Message));
            }
            finally
            {
                transition = false;
                phase = "";
            }
        }

        /// <summary>
        /// AUTO-TAGGING IS EXPLICIT (§4 rule 3). <c>Declare("stripe", tag:
        /// "?")</c> assigns the LOWEST UNUSED POSITIVE INTEGER tag and
        /// returns the assigned pair. Without <c>"?"</c>, a collision is
        /// an error.
        /// </summary>
        private string AutoTag(string name)
        {
            var n = 1L;
            while (true)
            {
                var cand = Refs.FormatRef(name, n.ToString(System.Globalization.CultureInfo.InvariantCulture));
                if (!inst.ContainsKey(cand))
                {
                    return cand;
                }
                n++;
            }
        }

        public Entry Declare(object eref, object spec)
        {
            var useref = eref;
            if ("?".Equals(Types.Get(spec, "tag")))
            {
                useref = AutoTag(Refs.RefName(Refs.CanonRef(eref)));
            }
            var r = Refs.CanonRef(useref);
            if (!Types.Truthy(Types.Get(spec, "hostowned")))
            {
                CheckReserved(r);
            }
            var defname = Types.Str(Types.Get(spec, "definition")) ?? Refs.RefName(r);
            var definition = catalog.Get(defname);
            if (null == definition)
            {
                Types.Fail("plugin_unknown_definition", "not in catalog: " + defname,
                           Types.Details("name", defname));
            }

            if (inst.TryGetValue(r, out var existing))
            {
                // §4 rule 1: a pair addresses at most one instance.
                // Re-declaring the SAME definition is the idempotent case;
                // a different one is a duplicate, not a silent overwrite
                // (seneca) and not an impossibility (sdkgen).
                if (existing.Def.Name != definition.Name)
                {
                    Types.Fail("plugin_ref_duplicate", "instance already declared: " + r,
                               Types.Details("ref", r));
                }
                return existing;
            }

            var entry = new Entry(r, definition);
            var pos = Types.Num(Types.Get(spec, "pos"));
            entry.Pos = pos ?? inst.Count;
            entry.Seq = seqn;
            entry.Options = Types.Get(spec, "options") ?? Types.NewMap();
            entry.OrderBlock = Types.Get(spec, "order");
            seqn++;
            inst[r] = entry;
            return entry;
        }

        /// <summary>
        /// §9.1: a host that reserves a name MUST still be able to declare
        /// the instance it reserved. THE BOUNDARY IS BY METHOD, NOT BY
        /// CALLER, and that is a real limit: no language here can tell the
        /// embedding host from a plugin holding the same host object. What
        /// reservation protects is CONFIGURATION - documents, overlays,
        /// <c>VOXGIG_PLUGIN_*</c>, construction options and ordinary
        /// declare/load/options - and all of that still checks.
        /// </summary>
        public Entry HostDeclare(object eref, object spec)
        {
            Guard();
            var owned = Types.NewMap();
            var given = Types.Map(spec);
            if (null != given)
            {
                foreach (var pair in given)
                {
                    owned[pair.Key] = pair.Value;
                }
            }
            owned["hostowned"] = true;
            return Declare(eref, owned);
        }

        public Entry Load(object eref, object spec)
        {
            Guard();
            var entry = Declare(eref, spec);
            if ("declared" != entry.Status)
            {
                return entry; // idempotent trivially
            }

            // PRESENCE, NOT TRUTH: an empty options map must CLEAR what
            // the instance was declared with.
            if (Types.Has(spec, "options") && null != Types.Get(spec, "options"))
            {
                entry.Options = Types.Get(spec, "options");
            }
            try
            {
                Run(entry, "define", "define");
            }
            catch (Exception)
            {
                entry.Status = "failed";
                throw;
            }
            entry.Status = "loaded";

            // AT LOAD, and before anything runs: a cycle through
            // restart-causing requirements does not settle, and the only
            // safe time to report a non-terminating reconcile is before it
            // starts (§11.3). `provides` is populated by `define`, which
            // has just run, so this is the first moment the graph is
            // complete.
            try
            {
                Depend.CheckCycle(GraphNodes());
            }
            catch (Exception)
            {
                entry.Status = "failed";
                throw;
            }
            return entry;
        }

        /// The requirement graph as plain data, for the pure detector.
        private List<Depend.Node> GraphNodes()
        {
            var out_ = new List<Depend.Node>();
            foreach (var pair in inst)
            {
                var provides = new List<string>();
                foreach (var p in pair.Value.Provides)
                {
                    provides.Add(Types.Str(Types.Get(p, "name")));
                }
                out_.Add(new Depend.Node(pair.Key, provides,
                                         Depend.Requirements(pair.Value.Options)));
            }
            return out_;
        }

        public Entry Activate(object eref)
        {
            Guard();
            var entry = Need(eref);
            if ("live" == entry.Status)
            {
                return entry; // no-op returning success
            }
            if ("failed" == entry.Status)
            {
                Types.Fail("plugin_bad_state", "instance has failed: " + entry.Ref,
                           Types.Details("ref", entry.Ref));
            }
            // §9.6: `active: false` bars the instance from running, and
            // the bar is on the INSTANCE rather than on the apply that set
            // it. `ready` reaches this through `activate`, so one guard
            // covers both verbs the design names.
            if (entry.Barred)
            {
                Types.Fail("plugin_inactive",
                           "instance is barred by active: false: " + entry.Ref,
                           Types.Details("ref", entry.Ref));
            }
            if ("declared" == entry.Status)
            {
                Load(entry.Ref, null);
            }

            // A declared requirement that is not live means `pending`:
            // activation is a STANDING REQUEST, not a one-shot event.
            var unmet = UnmetOf(entry);
            if (0 < unmet.Count)
            {
                entry.Unmet = unmet;
                entry.Status = "pending";
                return entry;
            }

            try
            {
                Run(entry, "activate", "activate");
            }
            catch (Exception)
            {
                // Unwind whatever the partial activation captured, in
                // reverse.
                Unwind(entry);
                entry.Status = "failed";
                throw;
            }
            // §11.4: THE SELECTION IS MADE HERE, once, and remembered.
            // Every later question - the cascade, `hold`, `unmet` - reads
            // it back rather than re-ranking, which is what
            // "always-reluctant" means.
            foreach (var req in Depend.Requirements(entry.Options))
            {
                Chosen(entry, req, true);
            }
            entry.Status = "live";
            Reconcile();
            return entry;
        }

        public Entry Deactivate(object eref)
        {
            Guard();
            var entry = Need(eref);
            if ("loaded" == entry.Status || "declared" == entry.Status)
            {
                return entry;
            }

            // §5.2: `unload` is THE ONLY TRANSITION OUT OF `failed`.
            if ("failed" == entry.Status)
            {
                Types.Fail("plugin_bad_state", "instance has failed: " + entry.Ref,
                           Types.Details("ref", entry.Ref));
            }

            if ("pending" == entry.Status)
            {
                // DEACTIVATING A PENDING INSTANCE RUNS NO CALLBACK (§5.2).
                // It never reached activate, so it holds no scope and no
                // live bindings; running the definition's deactivate there
                // would be teardown without matching setup, which plugins
                // are not written to survive and which could fail an
                // instance that had done nothing wrong. It cannot fail.
                entry.Status = "loaded";
                entry.Unmet = new List<string>();
                return entry;
            }

            Held(entry.Ref);
            Cascade(entry.Ref, new SortedSet<string>(StringComparer.Ordinal));

            try
            {
                Run(entry, "deactivate", "deactivate");
            }
            catch (Exception)
            {
                Unwind(entry);
                entry.Status = "failed";
                throw;
            }
            ReleaseCheck(entry, Unwind(entry));
            entry.Status = "loaded";
            Reconcile();
            return entry;
        }

        public void Unload(object eref)
        {
            Guard();
            var entry = Need(eref);
            if ("live" == entry.Status || "pending" == entry.Status)
            {
                if ("live" == entry.Status)
                {
                    Held(entry.Ref);
                    Cascade(entry.Ref, new SortedSet<string>(StringComparer.Ordinal));
                    try
                    {
                        Run(entry, "deactivate", "deactivate");
                    }
                    catch (Exception)
                    {
                        // §5.2: ANY failure during a transition lands the
                        // instance in `failed`, with the scope STILL FULLY
                        // UNWOUND - and the instance STAYS REGISTERED,
                        // because `failed` is a state an operator has to
                        // be able to see.
                        Unwind(entry);
                        entry.Status = "failed";
                        throw;
                    }
                    ReleaseCheck(entry, Unwind(entry));
                }
                entry.Status = "loaded";
            }
            if ("loaded" == entry.Status || "failed" == entry.Status)
            {
                try
                {
                    Run(entry, "close", "close");
                }
                finally
                {
                    inst.Remove(entry.Ref);
                }
                return;
            }
            inst.Remove(entry.Ref);
        }

        /// Runs the whole forward path in one call (§5.1).
        public Entry Ready(object eref)
        {
            Guard();
            var r = Refs.CanonRef(eref);
            if (!inst.ContainsKey(r))
            {
                Declare(r, null);
            }
            if ("declared" == inst[r].Status)
            {
                Load(r, null);
            }
            return Activate(r);
        }

        /// <summary>
        /// Bindings go live only when activation succeeds (§8.1), so the
        /// teardown is the exact inverse: reverse order, always. §8.3: "A
        /// failing release does not stop the rest. Every entry runs, in
        /// reverse order, whatever any of them does; the errors are
        /// collected and raised as one <c>plugin_release_failed</c>."
        ///
        /// <para>A selection belongs to ONE activation (§11.4). Leaving
        /// <c>live</c> by any door drops it, so the next activation ranks
        /// afresh.</para>
        /// </summary>
        private List<Exception> Unwind(Entry entry)
        {
            entry.Selected = new SortedDictionary<string, string>(StringComparer.Ordinal);
            var scope = entry.Scope;
            entry.Scope = new List<Entry.ScopeFn>();
            var errors = new List<Exception>();
            for (var i = scope.Count - 1; 0 <= i; i--)
            {
                try
                {
                    scope[i]();
                }
                catch (Exception e)
                {
                    errors.Add(e);
                }
            }
            return errors;
        }

        /// <summary>
        /// §8.3: "A failed release ends the instance in <c>failed</c>,
        /// exactly as a failed callback does (5.2) - a release that raised
        /// may have leaked, and an instance that may be holding resources
        /// it cannot account for must not be reactivated."
        /// </summary>
        private void ReleaseCheck(Entry entry, List<Exception> errors)
        {
            if (0 == errors.Count)
            {
                return;
            }
            entry.Status = "failed";
            var causes = new List<string>();
            foreach (var e in errors)
            {
                causes.Add(e.Message);
            }
            Types.Fail("plugin_release_failed",
                       "release failed for " + entry.Ref + ": " + string.Join("; ", causes),
                       Types.Details("ref", entry.Ref, "cause", Types.Strings(causes)));
        }

        /// <summary>
        /// A REQUIREMENT IS ON A CAPABILITY, not on a ref (§11.1). A bare
        /// string is shorthand for <c>{name}</c>. A ref satisfies too,
        /// because a host that genuinely needs a specific instance should
        /// not have to invent a capability for it.
        /// </summary>
        private List<string> UnmetOf(Entry entry)
        {
            var out_ = new List<string>();
            foreach (var req in Depend.Requirements(entry.Options))
            {
                if (!Depend.GatesActivation(req))
                {
                    continue;
                }
                if (0 != ProvidersOf(req).Count)
                {
                    continue;
                }
                out_.Add(Types.Str(Types.Get(req, "name")));
            }
            return out_;
        }

        /// <summary>
        /// §11.4's always-reluctant selection, and the ONE place a
        /// provider is picked for a live instance. If this instance
        /// already selected a provider for <c>req</c> and that provider is
        /// STILL a candidate, it keeps it - a better-ranked newcomer does
        /// not take it. <c>remember</c> is false for the questions asked
        /// ABOUT an instance rather than BY it: introspection must not
        /// create a binding.
        /// </summary>
        private string Chosen(Entry entry, object req, bool remember)
        {
            var cands = ProvidersOf(req);
            if (0 == cands.Count)
            {
                return null;
            }
            var name = Types.Str(Types.Get(req, "name"));
            if (entry.Selected.TryGetValue(name, out var held))
            {
                foreach (var c in cands)
                {
                    if (held == Types.Str(Types.Get(c, "ref")))
                    {
                        return held;
                    }
                }
            }
            var best = Types.Str(Types.Get(cands[0], "ref"));
            if (remember)
            {
                entry.Selected[name] = best;
            }
            return best;
        }

        private List<string> BoundProviders(Entry entry)
        {
            var out_ = new List<string>();
            foreach (var req in Depend.Requirements(entry.Options))
            {
                if (!Depend.RestartsOnLoss(req))
                {
                    continue;
                }
                var eref = Chosen(entry, req, false);
                if (null != eref && !out_.Contains(eref))
                {
                    out_.Add(eref);
                }
            }
            return out_;
        }

        /// Live instances whose selected provider is <c>eref</c> and which
        /// would be restarted by losing it.
        private List<string> ConsumersOf(string eref)
        {
            var out_ = new List<string>();
            foreach (var pair in new SortedDictionary<string, Entry>(inst, StringComparer.Ordinal))
            {
                if (pair.Key == eref || "live" != pair.Value.Status)
                {
                    continue;
                }
                if (BoundProviders(pair.Value).Contains(eref))
                {
                    out_.Add(pair.Key);
                }
            }
            return out_;
        }

        /// <summary>
        /// §11.3's <c>hold</c> asks a DIFFERENT question from the cascade,
        /// and reading it off <c>ConsumersOf</c> answered the cascade's.
        /// The cascade wants the edges that RESTART; <c>hold</c> says
        /// "deactivating a REQUIRED instance is
        /// <c>plugin_dependency_held</c>", and required is cardinality.
        /// The two sets differ in both directions and each difference was
        /// a real bug.
        /// </summary>
        private List<string> HoldersOf(string eref)
        {
            var out_ = new List<string>();
            foreach (var pair in new SortedDictionary<string, Entry>(inst, StringComparer.Ordinal))
            {
                if (pair.Key == eref || "live" != pair.Value.Status)
                {
                    continue;
                }
                foreach (var req in Depend.Requirements(pair.Value.Options))
                {
                    if (!Depend.GatesActivation(req))
                    {
                        continue;
                    }
                    if (eref == Chosen(pair.Value, req, false))
                    {
                        out_.Add(pair.Key);
                        break;
                    }
                }
            }
            return out_;
        }

        private List<object> ProvidersOf(object req)
        {
            var name = Types.Get(req, "name");
            var want = Refs.Canon(Types.Str(name));
            var cands = new List<object>();
            foreach (var pair in inst)
            {
                var target = pair.Value;
                if ("live" != target.Status)
                {
                    continue;
                }
                // A ref satisfies directly.
                if (pair.Key == want)
                {
                    var cand = Types.NewMap();
                    cand["ref"] = pair.Key;
                    cand["pos"] = target.Pos;
                    var prov = Types.NewMap();
                    prov["name"] = name;
                    cand["provides"] = prov;
                    cands.Add(cand);
                    continue;
                }
                foreach (var prov in target.Provides)
                {
                    if (!Types.Same(Types.Get(prov, "name"), name))
                    {
                        continue;
                    }
                    var cand = Types.NewMap();
                    cand["ref"] = pair.Key;
                    cand["pos"] = target.Pos;
                    cand["provides"] = prov;
                    cands.Add(cand);
                }
            }
            return Capability.ResolveCapability(req, cands);
        }

        /// <summary>
        /// CONSUMERS GO DOWN FIRST, NOT AFTERWARDS (§11.3). The cascade is
        /// part of the provider's own deactivation and runs BEFORE the
        /// provider's <c>deactivate</c> callback and scope unwind, so a
        /// consumer's teardown can still call the thing it depends on -
        /// flushing a buffer to the store it is about to lose is exactly
        /// what a <c>deactivate</c> callback is for.
        /// </summary>
        private void Cascade(string provider, SortedSet<string> seen)
        {
            if (seen.Contains(provider))
            {
                return;
            }
            seen.Add(provider);

            foreach (var r in ConsumersOf(provider))
            {
                if (!inst.TryGetValue(r, out var consumer) || "live" != consumer.Status)
                {
                    continue;
                }

                Cascade(r, seen); // deepest-first
                var bad = false;
                try
                {
                    Run(consumer, "deactivate", "deactivate");
                }
                catch (Exception)
                {
                    bad = true;
                }
                var errors = Unwind(consumer);
                if (bad || 0 != errors.Count)
                {
                    // §5.2: ANY failure during a transition lands the
                    // instance in `failed`. Marking it `pending` handed it
                    // straight back to `reconcile`, which would activate it
                    // again the moment the provider returned.
                    consumer.Status = "failed";
                    continue;
                }
                consumer.Status = "pending";
                consumer.Unmet = UnmetOf(consumer);
            }
        }

        /// <summary>
        /// The hold check is A GUARD ON AD-HOC DEACTIVATION, NOT ON
        /// COORDINATED TEARDOWN. In a bulk operation that is removing the
        /// holders too it is suspended for exactly those holders, and the
        /// teardown still runs consumers before providers.
        /// </summary>
        private void Held(string eref)
        {
            if ("hold" != dependency)
            {
                return;
            }
            if (coordinated)
            {
                return;
            }
            var holders = HoldersOf(eref);
            if (0 == holders.Count)
            {
                return;
            }
            Types.Fail("plugin_dependency_held",
                       "instance is required by live consumers: " + eref,
                       Types.Details("ref", eref, "holders", Types.Strings(holders)));
        }

        /// <summary>
        /// EAGER reconciliation: run to a fixed point rather than
        /// scheduling. Two directions, and both are the reason
        /// <c>pending</c> exists. Activation is a STANDING REQUEST, not a
        /// one-shot event.
        /// </summary>
        private void Reconcile()
        {
            var moved = true;
            var rounds = 0;
            while (moved)
            {
                moved = false;
                rounds++;
                if (1000 < rounds)
                {
                    break;
                }

                // Losses first, so a cascade settles in one pass rather
                // than alternating with re-activations.
                foreach (var r in new List<string>(inst.Keys))
                {
                    if (!inst.TryGetValue(r, out var entry) || "live" != entry.Status)
                    {
                        continue;
                    }
                    var lost = new List<object>();
                    foreach (var q in Depend.Requirements(entry.Options))
                    {
                        if (Depend.GatesActivation(q) && 0 == ProvidersOf(q).Count)
                        {
                            lost.Add(q);
                        }
                    }
                    if (0 == lost.Count)
                    {
                        continue;
                    }
                    // POLICY IS PER REQUIREMENT, not per instance (§11.3).
                    // A `dynamic` requirement whose provider is gone
                    // leaves the consumer LIVE and notified.
                    var restarts = false;
                    foreach (var q in lost)
                    {
                        if (Depend.RestartsOnLoss(q))
                        {
                            restarts = true;
                            break;
                        }
                    }
                    if (!restarts)
                    {
                        continue;
                    }

                    var bad = false;
                    try
                    {
                        Run(entry, "deactivate", "deactivate");
                    }
                    catch (Exception)
                    {
                        bad = true;
                    }
                    var errors = Unwind(entry);
                    if (bad || 0 != errors.Count)
                    {
                        entry.Status = "failed";
                        moved = true;
                        continue;
                    }
                    entry.Status = "pending";
                    entry.Unmet = UnmetOf(entry);
                    moved = true;
                }

                foreach (var r in new List<string>(inst.Keys))
                {
                    if (!inst.TryGetValue(r, out var entry) || "pending" != entry.Status)
                    {
                        continue;
                    }
                    if (0 != UnmetOf(entry).Count)
                    {
                        continue;
                    }
                    try
                    {
                        Run(entry, "activate", "activate");
                        entry.Status = "live";
                        entry.Unmet = new List<string>();
                        moved = true;
                    }
                    catch (Exception)
                    {
                        Unwind(entry);
                        entry.Status = "failed";
                        moved = true;
                    }
                }
            }
        }

        // --- ordering ---------------------------------------------------

        public List<string> Order(string point)
        {
            // Sorted by declaration SEQUENCE, which is what makes the §7
            // sort's fall-through deterministic in a language whose maps
            // have no insertion order. §7 breaks ties by `pos`; two
            // instances CAN share one, and past that this was falling
            // through to map order. `seq` is that order, made explicit.
            var live = new List<Entry>();
            foreach (var entry in inst.Values)
            {
                if ("live" == entry.Status)
                {
                    live.Add(entry);
                }
            }
            live = Types.StableSorted(live, (a, b) => a.Seq.CompareTo(b.Seq));

            var bindings = new List<Order.Binding>();
            foreach (var entry in live)
            {
                bindings.Add(new Order.Binding(entry.Ref, entry.Pos, entry.OrderBlock));
            }
            var pin = null == point ? null : Types.Get(Types.Get(points, point), "pin");
            return Voxgig.Plugin.Order.ResolveOrder(bindings, pin);
        }

        // --- points -----------------------------------------------------

        /// <summary>
        /// Live bindings on a point, in resolved order. Recomputed on any
        /// change to the live set (§7) rather than cached at startup - the
        /// bug a host discovers only when something deactivates in
        /// production.
        /// </summary>
        private List<Point.Bound> BoundOn(string point)
        {
            var out_ = new List<Point.Bound>();
            foreach (var eref in Order(point))
            {
                if (!inst.TryGetValue(eref, out var entry))
                {
                    continue;
                }
                // The band is the INSTANCE's ordering block (§7), stamped
                // by the host. A plugin passing its own would be ranking
                // itself above the order its document declared.
                var band = Types.AsInt(Types.Get(entry.OrderBlock, "band")) ?? 0;
                foreach (var b in entry.Bindings)
                {
                    if (b.PointName != point)
                    {
                        continue;
                    }
                    out_.Add(b.WithBand(band));
                }
            }
            return out_;
        }

        private object PointSpec(string point, string want)
        {
            if (!Types.Has(points, point))
            {
                Types.Fail("plugin_point_unknown", "no such point: " + point,
                           Types.Details("point", point));
            }
            var spec = Types.Get(points, point);
            var kind = Types.Get(spec, "kind");
            if ("hook" == want)
            {
                // A point with no declared kind is a hook, which is what
                // makes `{}` the minimal point declaration.
                if (null != kind && !"hook".Equals(kind))
                {
                    Types.Fail("plugin_point_kind", "point is not a hook: " + point,
                               Types.Details("point", point, "kind", kind));
                }
                return spec;
            }
            if (!want.Equals(kind))
            {
                Types.Fail("plugin_point_kind", "point is not a " + want + ": " + point,
                           Types.Details("point", point, "kind", kind));
            }
            return spec;
        }

        public object Emit(string point, object arg)
        {
            var spec = PointSpec(point, "hook");
            var mode = Types.Str(Types.Get(spec, "mode")) ?? "emit";
            return Point.Emit(BoundOn(point), mode, arg);
        }

        public object Call(string point, object[] args)
        {
            var spec = PointSpec(point, "chain");
            var base_ = Types.Get(spec, "base") as Point.NextFn;
            Point.NextFn basefn = null != base_
                ? base_
                : (a => 0 < a.Length ? a[0] : null);
            return Point.Compose(BoundOn(point), basefn)(args);
        }

        public object Provider(string point, object[] args)
        {
            var spec = PointSpec(point, "provider");
            var pick = Point.Provider(BoundOn(point), spec);
            if (null == pick.Winner)
            {
                return Types.Get(spec, "default");
            }
            return pick.Winner.Func(null, args);
        }

        /// The losers are VISIBLE rather than silently ignored (§6.3).
        public List<string> Shadowed(string point)
        {
            if (!Types.Has(points, point))
            {
                return new List<string>();
            }
            return Point.Provider(BoundOn(point), Types.Get(points, point)).Shadowed;
        }

        public object Exports(string spec)
        {
            var all = new List<Export.Exported>();
            foreach (var pair in inst)
            {
                var entry = pair.Value;
                // Exports of a `loaded` (not live) instance are VISIBLE (§11).
                if ("declared" == entry.Status || "failed" == entry.Status)
                {
                    continue;
                }
                foreach (var x in entry.Exports)
                {
                    all.Add(new Export.Exported(pair.Key, x.Key, x.Value));
                }
            }
            return Export.ResolveExport(spec, all);
        }

        /// The live providers of a capability, best-first (§11.1).
        public List<string> CapabilityOf(string name)
        {
            var cands = new List<object>();
            foreach (var pair in inst)
            {
                var entry = pair.Value;
                if ("live" != entry.Status)
                {
                    continue;
                }
                foreach (var prov in entry.Provides)
                {
                    if (name != Types.Str(Types.Get(prov, "name")))
                    {
                        continue;
                    }
                    var cand = Types.NewMap();
                    cand["ref"] = pair.Key;
                    cand["pos"] = entry.Pos;
                    cand["provides"] = prov;
                    cands.Add(cand);
                }
            }
            var req = Types.NewMap();
            req["name"] = name;
            var out_ = new List<string>();
            foreach (var c in Capability.ResolveCapability(req, cands))
            {
                out_.Add(Types.Str(Types.Get(c, "ref")));
            }
            return out_;
        }

        // --- documents --------------------------------------------------

        /// <summary>
        /// §9.6: "load what is missing, UNLOAD WHAT IS GONE, patch what
        /// changed, and move activation state to match", with the stated
        /// ordering. FOUR PHASES, NOT ONE INTERLEAVED LOOP: an earlier
        /// draft walked the document once, which never looked at instances
        /// the new document had DROPPED - so an integration removed from a
        /// config reload stayed live with its bindings and resources.
        /// </summary>
        public void Apply(object doc, object profile)
        {
            Guard();
            var useprofile = profile ?? Types.Get(opts, "profile");

            var input = Types.NewMap();
            input["doc"] = doc;
            input["profile"] = useprofile;
            input["keys"] = Types.Get(opts, "keys");
            input["reserved"] = reserved;
            var norm = Config.NormalizeConfig(input);

            var want = new List<string>();
            foreach (var r in Types.List(norm["order"]))
            {
                want.Add(Types.Str(r));
            }

            var defaults = Types.Get(opts, "defaults");
            var optionsof = new SortedDictionary<string, object>(StringComparer.Ordinal);
            foreach (var eref in want)
            {
                var oin = Types.NewMap();
                oin["ref"] = eref;
                oin["doc"] = doc;
                oin["profile"] = useprofile;
                oin["shape"] = ShapeOf(eref);
                oin["hostdefaults"] = Types.Get(defaults, Refs.RefName(eref));
                optionsof[eref] = Config.ResolveOptions(oin);
            }

            var instances = norm["instance"];

            // --- phase 1: deactivations and unloads, REVERSE load order ----
            var drop = new List<string>();
            foreach (var pair in inst)
            {
                if ("declared" == pair.Value.Status || WantLive(instances, pair.Key))
                {
                    continue;
                }
                drop.Add(pair.Key);
            }
            // Highest `pos` first, ref-descending for a tie, so a consumer
            // declared after its provider goes down first.
            drop.Sort((a, b) =>
            {
                var pa = inst[a].Pos;
                var pb = inst[b].Pos;
                if (pa != pb)
                {
                    return pb.CompareTo(pa);
                }
                return string.CompareOrdinal(b, a);
            });
            foreach (var eref in drop)
            {
                Unload(eref);
            }

            // --- phase 2: declare and patch EVERYTHING, in load order ------
            foreach (var eref in want)
            {
                var ent = Types.Get(instances, eref);
                var spec = Types.NewMap();
                spec["options"] = optionsof[eref];
                spec["order"] = Types.Get(ent, "order");
                spec["pos"] = Types.Get(ent, "pos");
                var entry = Declare(eref, spec);
                // The bar is REASSERTED ON EVERY APPLY, in both directions
                // - a document that turns the instance back on clears it,
                // which is the whole point of a config switch.
                entry.Barred = !Types.Truthy(Types.Get(ent, "active"));
                // REPLACE rather than refill: `Inst.Options()` reads the
                // field back through the entry every time, so no callback
                // is holding a map that needs emptying in place.
                entry.Options = optionsof[eref];
                entry.OrderBlock = Types.Get(ent, "order");
                entry.Pos = Types.Num(Types.Get(ent, "pos")) ?? 0;
            }

            // --- phase 3: loads, in load order -----------------------------
            // ONLY THE EAGER, ACTIVE ONES: "a document of twenty lazy
            // instances is twenty map entries and no executed code" (§9.6).
            foreach (var eref in want)
            {
                if (WantLive(instances, eref))
                {
                    Load(eref, null);
                }
            }

            // --- phase 4: activations, in load order -----------------------
            foreach (var eref in want)
            {
                if (WantLive(instances, eref))
                {
                    Activate(eref);
                }
            }
        }

        /// <summary>
        /// Should this ref be LIVE after the apply? False for a ref the
        /// document declares lazy or inactive AND for one it does not name
        /// at all - which is what makes "unload what is gone" and "unload
        /// what was toggled off" one rule rather than two.
        /// </summary>
        private static bool WantLive(object instances, string eref)
        {
            var ent = Types.Get(instances, eref);
            return null != ent && Types.Truthy(Types.Get(ent, "active"))
                && "eager".Equals(Types.Get(ent, "start"));
        }

        private object ShapeOf(string eref)
        {
            var definition = catalog.Get(Refs.RefName(eref));
            return null == definition ? null : definition.Shape;
        }

        public void Options(object eref, object patch)
        {
            Guard();
            var entry = Need(eref);
            var previous = entry.Options;

            var merged = Types.NewMap();
            var prev = Types.Map(previous);
            if (null != prev)
            {
                foreach (var pair in prev)
                {
                    merged[pair.Key] = pair.Value;
                }
            }
            foreach (var k in Types.Keys(patch))
            {
                merged[k] = Types.Get(patch, k);
            }

            var input = Types.NewMap();
            input["ref"] = entry.Ref;
            input["shape"] = ShapeOf(entry.Ref);
            input["doc"] = Types.NewMap();
            input["patch"] = merged;
            entry.Options = Config.ResolveOptions(input);

            if ("live" != entry.Status)
            {
                return;
            }

            if (null != entry.Def.Reconfigure)
            {
                transition = true;
                try
                {
                    entry.Def.Reconfigure(new Inst(this, entry), entry.Options, previous);
                }
                finally
                {
                    transition = false;
                }
            }
            else
            {
                // Always correct and sometimes expensive; `reconfigure`
                // exists to make the common case cheap (§9.4).
                Deactivate(entry.Ref);
                Activate(entry.Ref);
            }
        }

        public void Close()
        {
            // A bulk teardown removing the holders too, so `hold` is
            // suspended for exactly those holders (§11.3) - while the
            // consumers-first cascade still runs, which is the half that
            // matters.
            coordinated = true;
            try
            {
                var refs = new List<string>(inst.Keys);
                refs.Reverse();
                foreach (var eref in refs)
                {
                    if (inst.ContainsKey(eref))
                    {
                        Unload(eref);
                    }
                }
            }
            finally
            {
                coordinated = false;
            }
        }

        /// The same record §6.6 gives a plugin about itself, reachable
        /// from outside for the corpus.
        public object PositionOf(string eref, string point)
        {
            var myref = Refs.Canon(eref);
            if (!inst.TryGetValue(myref, out var entry))
            {
                Types.Fail("plugin_not_loaded", "no such instance: " + eref,
                           Types.Details("ref", eref));
            }
            var ranked = Order(point);
            var index = ranked.IndexOf(entry.Ref);
            var out_ = Types.NewMap();
            out_["index"] = (double)index;
            out_["count"] = (double)ranked.Count;
            // §6.2 composes b1(b2(b3(base))) with the FIRST binding
            // OUTERMOST, so these are not index 0 and index count-1 the
            // other way round.
            out_["outermost"] = 0 == index;
            out_["innermost"] = index == ranked.Count - 1;
            return out_;
        }
    }
}
