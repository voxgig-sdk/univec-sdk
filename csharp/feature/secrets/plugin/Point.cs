// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (csharp/src/Point.cs)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
using System;
using System.Collections.Generic;

namespace Voxgig.Plugin
{
    /// <summary>
    /// Extension points (§6). Three kinds, chosen because they are what
    /// the two existing systems actually needed, and no more.
    ///
    /// <para>A PLUGIN NEVER MUTATES THE HOST. That inversion is what makes
    /// deactivation possible: sdkgen's <c>utility.fetcher = wrapped</c> is
    /// not undoable, but "this instance holds slot 3 of the request chain"
    /// is undoable in O(1). OSGi named it the whiteboard pattern in 2004,
    /// in a paper called <i>Listeners Considered Harmful</i>, and for
    /// exactly this reason.</para>
    /// </summary>
    public static class Point
    {
        /// The next link of a chain (§6.2), or the base at the end of it.
        public delegate object NextFn(object[] args);

        /// <summary>
        /// EVERY binding has one signature, whatever kind of point it is
        /// on: a hook and a provider ignore the <c>next</c> they are
        /// handed, a chain uses it. One signature is what lets
        /// <c>Bound</c> return a single list the three callers share,
        /// rather than three parallel registries that can disagree about
        /// which instance holds slot 3.
        /// </summary>
        public delegate object BindFn(NextFn next, object[] args);

        public sealed class Bound
        {
            public readonly string Ref;
            public readonly string PointName;
            public readonly BindFn Func;
            public readonly long Band;

            public Bound(string eref, string point, BindFn func, long band)
            {
                Ref = eref;
                PointName = point;
                Func = func;
                Band = band;
            }

            public Bound WithBand(long band)
            {
                return new Bound(Ref, PointName, Func, band);
            }
        }

        /// §6.1: "fan-out" is not one answer but four.
        public static readonly string[] MODES = { "emit", "parallel", "serial", "bail" };

        /// Fan-out. Return values are ignored except in <c>bail</c>.
        public static object Emit(List<Bound> bindings, string mode, object arg)
        {
            if ("bail" == mode)
            {
                // Stops at the first binding that RETURNS A VALUE - the
                // "handled, stop" case. A `null` RETURN DECLINES (§6.1).
                // Not truthiness - `false`, `0` and `""` are values.
                foreach (var b in bindings)
                {
                    var v = b.Func(null, new object[] { arg });
                    if (null != v)
                    {
                        return v;
                    }
                }
                return null;
            }

            var errors = new List<object>();
            foreach (var b in bindings)
            {
                try
                {
                    b.Func(null, new object[] { arg });
                }
                catch (Exception e)
                {
                    // `emit` raises synchronously; the collecting modes
                    // gather.
                    if ("emit" == mode)
                    {
                        throw;
                    }
                    errors.Add(e.Message);
                }
            }
            return "emit" == mode ? null : (object)errors;
        }

        /// <summary>
        /// Composition: b1(b2(b3(base))), FIRST BINDING OUTERMOST (§6.2).
        ///
        /// <para>Plugins receive <c>next</c> as an argument; they never
        /// see or store the previous value of anything. A plugin that
        /// stashes <c>next</c> and calls it after deactivation is a bug
        /// the host cannot prevent, and this says so rather than
        /// pretending otherwise.</para>
        /// </summary>
        public static NextFn Compose(List<Bound> bindings, NextFn base_)
        {
            var next = base_;
            for (var i = bindings.Count - 1; 0 <= i; i--)
            {
                // Locals captured per iteration, so each layer closes over
                // its own pair - csharp's foreach-variable capture rule
                // changed in C# 5 and a `for` index would still need this.
                var func = bindings[i].Func;
                var inner = next;
                next = args => func(inner, args);
            }
            return next;
        }

        public sealed class Picked
        {
            public readonly Bound Winner;
            public readonly List<string> Shadowed;

            public Picked(Bound winner, List<string> shadowed)
            {
                Winner = winner;
                Shadowed = shadowed;
            }
        }

        /// <summary>
        /// At most one live implementation (§6.3). The winner is the
        /// highest band, ties broken by ref sort, and THE LOSERS ARE
        /// VISIBLE rather than silently ignored.
        /// </summary>
        public static Picked Provider(List<Bound> bindings, object spec)
        {
            if (0 == bindings.Count)
            {
                return new Picked(null, new List<string>());
            }

            if (Types.Truthy(Types.Get(spec, "exclusive")) && 1 < bindings.Count)
            {
                var refs = new List<string>();
                foreach (var b in bindings)
                {
                    refs.Add(b.Ref);
                }
                Types.SortStrings(refs);
                Types.Fail("plugin_point_exclusive",
                           "point is exclusive and has " + bindings.Count + " bindings: "
                           + string.Join(", ", refs),
                           Types.Details("refs", Types.Strings(refs)));
            }

            var ranked = Types.StableSorted(bindings, (a, b) =>
            {
                if (a.Band != b.Band)
                {
                    return a.Band < b.Band ? 1 : -1; // higher band first
                }
                return string.CompareOrdinal(a.Ref, b.Ref);
            });
            var shadowed = new List<string>();
            for (var i = 1; i < ranked.Count; i++)
            {
                shadowed.Add(ranked[i].Ref);
            }
            return new Picked(ranked[0], shadowed);
        }
    }
}
