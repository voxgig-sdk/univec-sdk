// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (csharp/src/Export.cs)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
using System;
using System.Collections.Generic;

namespace Voxgig.Plugin
{
    /// <summary>
    /// Exports (§11).
    ///
    /// <para>THE UNQUALIFIED ALIAS IS THE INTERESTING PART.
    /// <c>retry/client</c> resolves to the UNTAGGED instance if one
    /// exists; if not, and exactly one tagged instance exports that key,
    /// it resolves to that one; if two do, it is
    /// <c>plugin_export_ambiguous</c> - deliberately diverging from
    /// seneca's silent last-wins, because with multi-instance as a
    /// headline feature an ambiguous alias is a defect waiting for
    /// production.</para>
    /// </summary>
    public static class Export
    {
        /// One published value: which instance, under which key.
        public sealed class Exported
        {
            public readonly string Ref;
            public readonly string Key;
            public readonly object Value;

            public Exported(string eref, string key, object value)
            {
                Ref = eref;
                Key = key;
                Value = value;
            }
        }

        public static object ResolveExport(string spec, List<Exported> exported)
        {
            var cut = spec.IndexOf('/');
            if (cut < 0)
            {
                Types.Fail("plugin_export_ambiguous", "export spec needs a key: " + spec,
                           Types.Details("spec", spec));
            }
            var head = spec.Substring(0, cut);
            var key = spec.Substring(cut + 1);

            // A fully qualified ref: exactly one answer or none.
            var want = Refs.Canon(head);
            foreach (var e in exported)
            {
                if (e.Ref == want && e.Key == key)
                {
                    return e.Value;
                }
            }

            // An alias: the name, not a ref. Look at every instance of it.
            var byname = new List<Exported>();
            foreach (var e in exported)
            {
                if (Refs.RefName(e.Ref) == head && e.Key == key)
                {
                    byname.Add(e);
                }
            }
            if (0 == byname.Count)
            {
                return null;
            }

            foreach (var e in byname)
            {
                if (0 == Types.Str(Refs.ParseRef(e.Ref)["tag"]).Length)
                {
                    return e.Value;
                }
            }

            if (1 == byname.Count)
            {
                return byname[0].Value;
            }

            var refs = new List<string>();
            foreach (var e in byname)
            {
                refs.Add(e.Ref);
            }
            Types.SortStrings(refs);
            Types.Fail("plugin_export_ambiguous",
                       "alias " + spec + " matches " + refs.Count + " instances: "
                       + string.Join(", ", refs),
                       // `spec` is not one of §12's fields, so it does not
                       // render - the same detail map every other port
                       // builds, and the same message.
                       Types.Details("spec", spec, "refs", Types.Strings(refs)));
            return null;
        }
    }
}
