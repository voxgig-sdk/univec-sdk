// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (csharp/src/Entry.cs)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
using System;
using System.Collections.Generic;

namespace Voxgig.Plugin
{
    /// One instance's record. Mutable, and owned by the host.
    public sealed class Entry
    {
        /// A registered teardown (§8.3).
        public delegate void ScopeFn();

        public readonly string Ref;
        public readonly Definition Def;
        public string Status = "declared";
        public double Pos;
        public double Seq;
        public object Options = Types.NewMap();

        /// <summary>
        /// The mutable per-instance state a definition owns (§5.4). A
        /// reference, so the counter surviving a deactivate/activate cycle
        /// is this object and nothing else.
        /// </summary>
        public readonly SortedDictionary<string, object> State = Types.NewMap();

        public object OrderBlock;
        public List<string> Unmet = new List<string>();
        public List<ScopeFn> Scope = new List<ScopeFn>();

        /// <summary>
        /// §11.4's ALWAYS-RELUCTANT rebinding made concrete: the provider
        /// ref this instance's activation actually chose, per requirement
        /// name. Re-ranking on every question silently re-points a live
        /// consumer at any better newcomer, and then losing the provider it
        /// was really using does not restart it.
        /// </summary>
        public SortedDictionary<string, string> Selected =
            new SortedDictionary<string, string>(StringComparer.Ordinal);

        public List<Point.Bound> Bindings = new List<Point.Bound>();
        public readonly SortedDictionary<string, object> Exports = Types.NewMap();
        public List<object> Provides = new List<object>();
        public Host Inner;
        public bool Barred;

        public Entry(string eref, Definition def)
        {
            Ref = eref;
            Def = def;
        }
    }
}
