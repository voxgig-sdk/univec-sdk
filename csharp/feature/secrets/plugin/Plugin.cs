// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (csharp/src/Plugin.cs)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
using System;
using System.Collections.Generic;

namespace Voxgig.Plugin
{
    /// <summary>
    /// The canonical surface <c>make parity</c> checks (AGENTS.md §4).
    ///
    /// <para>Small on purpose (§19): everything else is methods on
    /// <see cref="Host"/> and <see cref="Inst"/>, because a library that
    /// grows a second public entry point per feature is a library twenty
    /// ports pay for twice.</para>
    ///
    /// <para>This class FORWARDS rather than implements. The surface is
    /// visible in one place, and a name that stops existing stops existing
    /// here loudly.</para>
    /// </summary>
    public static class Plugin
    {
        public static Host MakeHost(object options)
        {
            return Host.MakeHost(options);
        }

        public static Catalog MakeCatalog(List<Definition> definitions)
        {
            return Catalog.MakeCatalog(definitions);
        }

        public static SortedDictionary<string, object> ParseRef(object eref)
        {
            return Refs.ParseRef(eref);
        }

        public static string FormatRef(object name, object tag)
        {
            return Refs.FormatRef(name, tag);
        }

        public static bool CheckName(object name)
        {
            return Refs.CheckName(name);
        }

        public static bool CheckTag(object tag)
        {
            return Refs.CheckTag(tag);
        }

        public static string CanonRef(object eref)
        {
            return Refs.CanonRef(eref);
        }

        public static SortedDictionary<string, object> NormalizeConfig(object input)
        {
            return Config.NormalizeConfig(input);
        }

        public static SortedDictionary<string, object> ResolveOptions(object input)
        {
            return Config.ResolveOptions(input);
        }

        public static List<string> ResolveOrder(List<Order.Binding> bindings, object pin)
        {
            return Order.ResolveOrder(bindings, pin);
        }

        public static List<object> ResolveCandidates(string name, object sources)
        {
            return Resolve.ResolveCandidates(name, sources);
        }

        public static List<object> ResolveFrom(object from)
        {
            return Resolve.ResolveFrom(from);
        }

        public static List<object> ResolveCapability(object req, List<object> candidates)
        {
            return Capability.ResolveCapability(req, candidates);
        }

        public static SortedDictionary<string, object> ResolveGraph(object nodes)
        {
            return Graph.ResolveGraph(nodes);
        }

        public static SortedDictionary<string, object> ApplyEnv(object input)
        {
            return Env.ApplyEnv(input);
        }

        public static SortedDictionary<string, object> ParseRange(object range)
        {
            return Version.ParseRange(range);
        }

        public static bool Satisfies(object version, object range)
        {
            return Version.Satisfies(version, range);
        }

        public static string CodeOf(Exception err)
        {
            return Types.CodeOf(err);
        }
    }
}
