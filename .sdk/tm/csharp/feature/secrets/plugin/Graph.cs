// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (csharp/src/Graph.cs)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
using System;
using System.Collections.Generic;

namespace Voxgig.Plugin
{
    /// <summary>
    /// Whole-graph resolution (§11.4) - a phase, not a discovery.
    ///
    /// <para>"Activate, and wait in <c>pending</c> if you must" is correct
    /// and, on its own, produces a terrible experience: apply twenty
    /// instances against a registry missing one thing and you get NINETEEN
    /// pending rows and no statement of what is actually wrong.</para>
    ///
    /// <para>The failure mode being designed against is a famous one:
    /// OSGi's resolver is correct and its diagnostics are legendarily
    /// unusable. A resolver that says "blocked" without saying WHY has
    /// moved the problem rather than solved it, so <c>why</c> is part of
    /// the contract and the corpus pins its shape.</para>
    /// </summary>
    public static class Graph
    {
        public static SortedDictionary<string, object> ResolveGraph(object nodes)
        {
            var all = Types.List(nodes) ?? new List<object>();

            var byref = new SortedDictionary<string, object>(StringComparer.Ordinal);
            foreach (var n in all)
            {
                byref[Types.Str(Types.Get(n, "ref"))] = n;
            }

            var resolved = new SortedSet<string>(StringComparer.Ordinal);
            var blocked = new SortedDictionary<string, object>(StringComparer.Ordinal);

            // Fixed point: a node resolves when every mandatory
            // requirement is met by an ALREADY-RESOLVED provider.
            // Iterating to a fixed point is what makes a provider that is
            // itself blocked propagate, rather than each node being judged
            // against the raw registry.
            var moved = true;
            while (moved)
            {
                moved = false;
                foreach (var n in all)
                {
                    var eref = Types.Str(Types.Get(n, "ref"));
                    if (resolved.Contains(eref))
                    {
                        continue;
                    }
                    if (null != FirstUnmet(n, byref, resolved))
                    {
                        continue;
                    }
                    resolved.Add(eref);
                    moved = true;
                }
            }

            foreach (var n in all)
            {
                var eref = Types.Str(Types.Get(n, "ref"));
                if (resolved.Contains(eref))
                {
                    continue;
                }
                var why = FirstUnmet(n, byref, resolved);
                if (null != why)
                {
                    blocked[eref] = why;
                }
            }

            var out_ = Types.NewMap();
            out_["resolved"] = Types.Strings(new List<string>(resolved));
            out_["blocked"] = new List<object>(blocked.Values);
            return out_;
        }

        /// <summary>
        /// The FIRST unmet requirement, with the most specific explanation
        /// available. Order matters: "no provider at all" and "a provider
        /// at the wrong version" are different problems and a reader must
        /// not have to guess which they have.
        /// </summary>
        private static object FirstUnmet(
            object node, SortedDictionary<string, object> byref, SortedSet<string> resolved)
        {
            var requires = Types.List(Types.Get(node, "requires")) ?? new List<object>();

            foreach (var req in requires)
            {
                if (Types.Truthy(Types.Get(req, "optional")))
                {
                    continue;
                }
                var name = Types.Get(req, "name");
                var all = Candidates(byref, name);
                if (0 == all.Count)
                {
                    return Unmet(node, name, Why("absent"));
                }

                var ok = Capability.ResolveCapability(req, all);
                if (0 < ok.Count)
                {
                    // A provider exists and matches - but if none of them
                    // is itself resolved, this node is blocked BEHIND it,
                    // and the chain is the useful answer rather than
                    // "unmet".
                    var any = false;
                    foreach (var c in ok)
                    {
                        if (resolved.Contains(Types.Str(Types.Get(c, "ref"))))
                        {
                            any = true;
                            break;
                        }
                    }
                    if (any)
                    {
                        continue;
                    }
                    var chain = new List<string>();
                    foreach (var c in ok)
                    {
                        chain.Add(Types.Str(Types.Get(c, "ref")));
                    }
                    Types.SortStrings(chain);
                    var w = Types.NewMap();
                    w["kind"] = "blocked";
                    w["chain"] = Types.Strings(chain);
                    return Unmet(node, name, w);
                }

                // Providers exist and none matched. Say which test failed.
                var range = Types.Get(req, "range");
                if (null != range)
                {
                    var versions = new List<string>();
                    foreach (var c in all)
                    {
                        var have = Types.Get(Types.Get(c, "provides"), "version");
                        if (null == have || !Version.SatisfiesQ(have, range))
                        {
                            versions.Add(null == have ? "(none)" : Types.Str(have));
                        }
                    }
                    if (0 < versions.Count)
                    {
                        Types.SortStrings(versions);
                        var w = Types.NewMap();
                        w["kind"] = "version";
                        w["range"] = range;
                        w["found"] = Types.Strings(versions);
                        return Unmet(node, name, w);
                    }
                }

                var want = Types.Get(req, "match");
                if (null != want)
                {
                    foreach (var c in all)
                    {
                        var attrs = Types.Get(Types.Get(c, "provides"), "attrs");
                        foreach (var k in Types.Keys(want))
                        {
                            if (Types.Has(attrs, k)
                                && Capability.MatchValue(Types.Get(want, k), Types.Get(attrs, k)))
                            {
                                continue;
                            }
                            var w = Types.NewMap();
                            w["kind"] = "match";
                            w["failing"] = k;
                            w["want"] = Types.Get(want, k);
                            w["found"] = Types.Get(attrs, k);
                            return Unmet(node, name, w);
                        }
                    }
                }

                return Unmet(node, name, Why("absent"));
            }
            return null;
        }

        private static SortedDictionary<string, object> Why(string kind)
        {
            var out_ = Types.NewMap();
            out_["kind"] = kind;
            return out_;
        }

        private static SortedDictionary<string, object> Unmet(object node, object name, object why)
        {
            var out_ = Types.NewMap();
            out_["ref"] = Types.Get(node, "ref");
            out_["unmet"] = name;
            out_["why"] = why;
            return out_;
        }

        private static List<object> Candidates(
            SortedDictionary<string, object> byref, object name)
        {
            var out_ = new List<object>();
            // A NODE SATISFIES ITS OWN REF (§11.1), and the graph learned
            // it here. Considering only declared capabilities made
            // `Resolve` answer `absent` about a provider sitting right
            // there and live - §11.4's job is explaining the graph the
            // runtime reconciles, and it was explaining a different one.
            var asref = Refs.Canon(Types.Str(name) ?? "");
            // The map is sorted, so the walk is - which is the whole
            // reason it is a SortedDictionary.
            foreach (var node in byref.Values)
            {
                // The ref match WINS OUTRIGHT for that node, as at
                // runtime: one candidate, not two, for a node both named
                // `b` and providing `b`.
                if (asref == Types.Str(Types.Get(node, "ref")))
                {
                    var refcand = Types.NewMap();
                    refcand["ref"] = Types.Get(node, "ref");
                    refcand["pos"] = Types.Num(Types.Get(node, "pos")) ?? 0.0;
                    var prov0 = Types.NewMap();
                    prov0["name"] = name;
                    refcand["provides"] = prov0;
                    out_.Add(refcand);
                    continue;
                }
                var provides = Types.List(Types.Get(node, "provides"));
                if (null == provides)
                {
                    continue;
                }
                foreach (var prov in provides)
                {
                    if (!Types.Same(Types.Get(prov, "name"), name))
                    {
                        continue;
                    }
                    var cand = Types.NewMap();
                    cand["ref"] = Types.Get(node, "ref");
                    cand["pos"] = Types.Num(Types.Get(node, "pos")) ?? 0.0;
                    cand["provides"] = prov;
                    out_.Add(cand);
                }
            }
            return out_;
        }
    }
}
