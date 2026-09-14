// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (csharp/src/Capability.cs)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
using System;
using System.Collections.Generic;

namespace Voxgig.Plugin
{
    /// <summary>
    /// Capabilities (§11.1).
    ///
    /// <para>A DEPENDENCY IS ON A CAPABILITY, NOT ON A REF - because it is
    /// a dependency on something that can do the job, and which instance
    /// is doing it is exactly the configuration detail a plugin must not
    /// care about.</para>
    ///
    /// <para>But A BINDING IS TO AN INSTANCE, not to a capability, which
    /// is what decides behaviour when the bound provider leaves while
    /// another match remains.</para>
    /// </summary>
    public static class Capability
    {
        /// <summary>
        /// Rank the matching live providers and return them best-first:
        /// highest <c>version</c>, then LOWEST <c>priority</c> (default
        /// 0), then declaration position <c>pos</c> ascending.
        ///
        /// <para><c>priority</c> is a field on the capability rather than
        /// §7's <c>order</c> band, because bands live on POINT BINDINGS: a
        /// provider may have several bindings with different bands, or
        /// none at all, so a rank reaching for one would be undefined in
        /// the common case.</para>
        ///
        /// <para>Without a total rank, "any provider satisfies" is true of
        /// the GRAPH and useless to the PLUGIN - two ports could bind
        /// different <c>store</c> instances, both resolve green, and
        /// behave differently, which is precisely the divergence a shared
        /// corpus exists to catch.</para>
        /// </summary>
        public static List<object> ResolveCapability(object req, List<object> candidates)
        {
            var hits = new List<object>();
            foreach (var c in candidates)
            {
                if (Matches(req, Types.Get(c, "provides")))
                {
                    hits.Add(c);
                }
            }
            return Types.StableSorted(hits, CompareRank);
        }

        private static int CompareRank(object a, object b)
        {
            var pa = Types.Get(a, "provides");
            var pb = Types.Get(b, "provides");
            var va = Types.Str(Types.Get(pa, "version"));
            var vb = Types.Str(Types.Get(pb, "version"));

            // An ABSENT version sorts LAST, whatever the other is - "no
            // version" loses to every version rather than being read as
            // 0.0.0.
            var absent = (null == va).CompareTo(null == vb);
            if (0 != absent)
            {
                return absent;
            }
            if (null != va)
            {
                var la = Version.VersionParts(va);
                var lb = Version.VersionParts(vb);
                for (var i = 0; i < Math.Max(la.Count, lb.Count); i++)
                {
                    var x = i < la.Count ? la[i] : 0;
                    var y = i < lb.Count ? lb[i] : 0;
                    if (x != y)
                    {
                        return x < y ? 1 : -1; // higher version first
                    }
                }
            }

            var qa = Types.Num(Types.Get(pa, "priority")) ?? 0;
            var qb = Types.Num(Types.Get(pb, "priority")) ?? 0;
            if (qa != qb)
            {
                return qa < qb ? -1 : 1;
            }

            var sa = Types.Num(Types.Get(a, "pos")) ?? 0;
            var sb = Types.Num(Types.Get(b, "pos")) ?? 0;
            return sa.CompareTo(sb);
        }

        public static bool Matches(object req, object prov)
        {
            if (!Types.Same(Types.Get(req, "name"), Types.Get(prov, "name")))
            {
                return false;
            }

            var range = Types.Get(req, "range");
            if (null != range)
            {
                var version = Types.Get(prov, "version");
                if (null == version)
                {
                    return false;
                }
                if (!Version.SatisfiesQ(version, range))
                {
                    return false;
                }
            }

            // `match` is checked against the provider's `attrs`, key by
            // key. A key the provider does not carry is a miss, not a
            // pass: a requirement asking for `transactional: true` must not
            // be satisfied by a provider that never said.
            var want = Types.Get(req, "match");
            if (null != want)
            {
                var attrs = Types.Get(prov, "attrs");
                foreach (var key in Types.Keys(want))
                {
                    if (!Types.Has(attrs, key))
                    {
                        return false;
                    }
                    if (!MatchValue(Types.Get(want, key), Types.Get(attrs, key)))
                    {
                        return false;
                    }
                }
            }

            return true;
        }

        /// <summary>
        /// PARTIAL MATCH, RECURSING INTO MAPS (§11.1).
        ///
        /// <para>Equality is by JSON TYPE as well as value:
        /// <c>transactional: 1</c> does not satisfy <c>transactional:
        /// true</c>. CSHARP NEEDS NO GUARD FOR THAT - a boxed bool and a
        /// boxed double are different types with no coercion between them
        /// - so the explicit check php, perl and lua each carry would be
        /// dead code here.</para>
        ///
        /// <para>A LIST IS COMPARED LEAF-WISE AT THE SAME LENGTH, not as a
        /// subset.</para>
        /// </summary>
        public static bool MatchValue(object want, object got)
        {
            if (null != Types.Map(want))
            {
                if (null == Types.Map(got))
                {
                    return false;
                }
                foreach (var key in Types.Keys(want))
                {
                    if (!Types.Has(got, key))
                    {
                        return false;
                    }
                    if (!MatchValue(Types.Get(want, key), Types.Get(got, key)))
                    {
                        return false;
                    }
                }
                return true;
            }

            var wl = Types.List(want);
            if (null != wl)
            {
                var gl = Types.List(got);
                if (null == gl || wl.Count != gl.Count)
                {
                    return false;
                }
                for (var i = 0; i < wl.Count; i++)
                {
                    if (!MatchValue(wl[i], gl[i]))
                    {
                        return false;
                    }
                }
                return true;
            }

            return Types.Same(want, got);
        }
    }
}
