// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (csharp/src/Order.cs)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
using System;
using System.Collections.Generic;

namespace Voxgig.Plugin
{
    /// <summary>
    /// Ordering (§7) - one rule, one place.
    ///
    /// <para>sdkgen grew two special cases in <c>makeOptions</c> and the
    /// third was not far off. This sort is the whole replacement, and the
    /// tiers are: constraints (before/after edges, by ref or by name),
    /// then bands (integer, lower first, default 0), then declaration ties
    /// by <c>pos</c>.</para>
    ///
    /// <para>CONSTRAINTS BEAT BANDS precisely so the correct tool wins
    /// when both are present. A band expresses a genuine cross-cutting
    /// layer; a constraint expresses a relationship between two specific
    /// things; and a band chosen by trial and error to fix an ordering bug
    /// is a bug wearing a number.</para>
    /// </summary>
    public static class Order
    {
        /// One thing to place: its ref, its position, and its block as authored.
        public sealed class Binding
        {
            public readonly string Ref;
            public readonly double Pos;
            public readonly object OrderBlock;

            public Binding(string eref, double pos, object order)
            {
                Ref = eref;
                Pos = pos;
                OrderBlock = order;
            }
        }

        public static List<string> ResolveOrder(List<Binding> bindings, object pin)
        {
            var byref = new Dictionary<string, Binding>(StringComparer.Ordinal);
            foreach (var b in bindings)
            {
                byref[b.Ref] = b;
            }

            // Constraints are edges. A constraint naming an ABSENT binding
            // is satisfied VACUOUSLY (§7) - a plugin ordered `after:
            // 'test'` must load in a host with no test plugin. That is
            // sdkgen's __after__ behaviour, kept.
            var edges = new SortedDictionary<string, List<string>>(StringComparer.Ordinal);
            var indeg = new SortedDictionary<string, int>(StringComparer.Ordinal);
            foreach (var b in bindings)
            {
                edges[b.Ref] = new List<string>();
                indeg[b.Ref] = 0;
            }

            foreach (var b in bindings)
            {
                var block = b.OrderBlock;
                // An ABSENT constraint and an EMPTY LIST are both "no
                // constraint".
                if (Declared(Types.Get(block, "after")))
                {
                    foreach (var t in Targets(Types.Get(block, "after"), bindings))
                    {
                        edges[t].Add(b.Ref);
                    }
                }
                if (Declared(Types.Get(block, "before")))
                {
                    edges[b.Ref].AddRange(Targets(Types.Get(block, "before"), bindings));
                }
            }

            foreach (var tos in edges.Values)
            {
                foreach (var to in tos)
                {
                    indeg[to] = indeg[to] + 1;
                }
            }

            // Stable topological sort. Among ready nodes, band first
            // (lower runs first), then `pos` - the position the DOCUMENT
            // visibly states, not the order instances happened to load and
            // not the incarnation `seq`.
            var out_ = new List<string>();
            var ready = new List<Binding>();
            foreach (var b in bindings)
            {
                if (0 == indeg[b.Ref])
                {
                    ready.Add(b);
                }
            }

            while (0 < ready.Count)
            {
                ready = Types.StableSorted(ready, (x, y) =>
                {
                    var bx = Band(x.OrderBlock);
                    var by = Band(y.OrderBlock);
                    if (bx != by)
                    {
                        return bx < by ? -1 : 1;
                    }
                    return x.Pos.CompareTo(y.Pos);
                });
                var next = ready[0];
                ready.RemoveAt(0);
                out_.Add(next.Ref);
                foreach (var to in edges[next.Ref])
                {
                    indeg[to] = indeg[to] - 1;
                    if (0 == indeg[to])
                    {
                        ready.Add(byref[to]);
                    }
                }
            }

            if (out_.Count != bindings.Count)
            {
                var stuck = new List<string>();
                foreach (var b in bindings)
                {
                    if (!out_.Contains(b.Ref))
                    {
                        stuck.Add(b.Ref);
                    }
                }
                Types.Fail("plugin_order_cycle",
                           "before/after constraints cycle: " + string.Join(" -> ", stuck),
                           Types.Details("cycle", Types.Strings(stuck)));
            }

            return ApplyPin(out_, edges, pin);
        }

        /// An integer, and only an integer: <c>true</c> and <c>"2"</c> are not bands.
        public static long Band(object block)
        {
            return Types.AsInt(Types.Get(block, "band")) ?? 0;
        }

        /// <summary>
        /// Was a constraint stated? An absent value and an EMPTY LIST are
        /// both no-constraint - and an empty list is TRUTHY in most
        /// languages, which is exactly how this class of bug survives a
        /// reading.
        /// </summary>
        public static bool Declared(object spec)
        {
            if (null == spec)
            {
                return false;
            }
            var list = Types.List(spec);
            if (null != list)
            {
                foreach (var one in list)
                {
                    if (!"".Equals(one))
                    {
                        return true;
                    }
                }
                return false;
            }
            return !"".Equals(spec);
        }

        /// <summary>
        /// One spelling or a LIST of them. A list fans out to the UNION of
        /// what each names, so after: ['a','b'] means after BOTH, and the
        /// same instance named twice - once by name, once by ref - is one
        /// edge.
        /// </summary>
        public static List<string> Targets(object spec, List<Binding> nodes)
        {
            var specs = Types.List(spec) ?? new List<object> { spec };
            var hit = new List<string>();
            foreach (var one in specs)
            {
                var want = Types.Str(one);
                if (null == want)
                {
                    continue;
                }
                foreach (var b in nodes)
                {
                    if (hit.Contains(b.Ref))
                    {
                        continue;
                    }
                    if (b.Ref == want || Refs.RefName(b.Ref) == want)
                    {
                        hit.Add(b.Ref);
                    }
                }
            }
            return hit;
        }

        /// <summary>
        /// A PIN IS NOT A CONSTRAINT (§7).
        ///
        /// <para>Constraints and bands are negotiable by definition - they
        /// are what plugins and documents say they want. A pin is the host
        /// stating a structural invariant of its own architecture, which
        /// is a different kind of claim and must not lose a tie to a
        /// document. So a pin PLACES the binding at the named end, and an
        /// ordering that would move it away is
        /// <c>plugin_order_pinned</c> - rejected, not honoured into a
        /// broken wrap.</para>
        /// </summary>
        private static List<string> ApplyPin(
            List<string> order, SortedDictionary<string, List<string>> edges, object pin)
        {
            if (null == pin)
            {
                return order;
            }

            var out_ = new List<string>(order);

            // SORTED, not insertion order. A pin map is data - it can
            // arrive from a host's own construction options in any order,
            // and two names pinned to the same end are order-sensitive.
            foreach (var name in Types.Keys(pin))
            {
                var want = Types.Get(pin, name);
                var idx = -1;
                for (var i = 0; i < out_.Count; i++)
                {
                    if (Refs.RefName(out_[i]) == name)
                    {
                        idx = i;
                        break;
                    }
                }
                if (idx < 0)
                {
                    continue;
                }

                // `first`/`outermost` is index 0; `last`/`innermost` is
                // the end. §6.2 makes the first chain binding outermost,
                // which is why the vocabulary is positional and why the
                // two spellings pair this way.
                var wantfirst = "first".Equals(want) || "outermost".Equals(want);
                var eref = out_[idx];
                out_.RemoveAt(idx);
                if (wantfirst)
                {
                    out_.Insert(0, eref);
                }
                else
                {
                    out_.Add(eref);
                }
            }

            // Now check that the placement did not break a constraint.
            // This is the half that makes a pin a rejection rather than an
            // override: the host wins on position, but it does not get to
            // silently discard a relationship a plugin declared.
            var at = new Dictionary<string, int>(StringComparer.Ordinal);
            for (var i = 0; i < out_.Count; i++)
            {
                at[out_[i]] = i;
            }
            foreach (var pair in edges)
            {
                foreach (var to in pair.Value)
                {
                    if (at[pair.Key] <= at[to])
                    {
                        continue;
                    }
                    Types.Fail("plugin_order_pinned",
                               "a pin would move a binding an ordering constrains: "
                               + pair.Key + " must precede " + to,
                               Types.Details("before", pair.Key, "after", to));
                }
            }

            return out_;
        }
    }
}
