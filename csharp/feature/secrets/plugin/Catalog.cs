// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (csharp/src/Catalog.cs)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
using System;
using System.Collections.Generic;

namespace Voxgig.Plugin
{
    /// <summary>
    /// The definition catalog (§10.1).
    ///
    /// <para>A definition is registered once and may back many instances.
    /// Option shapes are validated AT REGISTRATION, not when a document
    /// happens to exercise a key - so a malformed shape fails once, and in
    /// the same place everywhere (§9.4).</para>
    /// </summary>
    public sealed class Catalog
    {
        private readonly SortedDictionary<string, Definition> defs =
            new SortedDictionary<string, Definition>(StringComparer.Ordinal);

        public void Add(Definition definition)
        {
            if (null == definition || !Refs.CheckName(definition.Name))
            {
                Types.Fail("plugin_definition_name",
                           "invalid definition name: "
                           + (null == definition ? "null" : definition.Name),
                           null);
            }
            // Validate the shape HERE. Deferring it to resolution time
            // means a malformed shape surfaces at a different moment in
            // every host that loads it, which is the divergence the stated
            // domain exists to prevent.
            if (Types.Truthy(definition.Shape))
            {
                Config.CheckShape(definition.Shape);
            }
            defs[definition.Name] = definition;
        }

        public Definition Get(string name)
        {
            return defs.TryGetValue(name, out var d) ? d : null;
        }

        public bool Has(string name)
        {
            return defs.ContainsKey(name);
        }

        public List<string> Names()
        {
            return new List<string>(defs.Keys);
        }

        public static Catalog MakeCatalog(List<Definition> definitions)
        {
            var catalog = new Catalog();
            if (null != definitions)
            {
                foreach (var d in definitions)
                {
                    catalog.Add(d);
                }
            }
            return catalog;
        }
    }
}
