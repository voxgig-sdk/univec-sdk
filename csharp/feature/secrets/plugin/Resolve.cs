// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (csharp/src/Resolve.cs)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
using System;
using System.Collections.Generic;

namespace Voxgig.Plugin
{
    /// <summary>
    /// Dynamic resolution (§10.2) - name to candidate module ids.
    ///
    /// <para>PURE. It returns the ids a host WOULD try, in order; it does
    /// not load anything. That separation is what lets the corpus pin
    /// resolution in every language including those with no dynamic
    /// loading at all, and it is why §15.4 puts real module loading in
    /// per-port integration tests rather than here.</para>
    /// </summary>
    public static class Resolve
    {
        public static List<object> DefaultSources()
        {
            var src = Types.NewMap();
            src["kind"] = "module";
            src["prefix"] = new List<object>
            {
                "@voxgig/plugin-", "voxgig-plugin-", "plugin-", "",
            };
            return new List<object> { src };
        }

        public static List<object> ResolveCandidates(string name, object sources)
        {
            var out_ = new List<object>();

            // A SCOPED NAME RESOLVES VERBATIM ONLY (§10.2). `@acme/thing`
            // is already a package id; prefixing it produces
            // `@voxgig/plugin-@acme/thing`, which is not a thing that can
            // exist.
            if (name.StartsWith("@", StringComparison.Ordinal))
            {
                out_.Add(name);
                return out_;
            }

            var given = Types.List(sources);
            var list = (null == given || 0 == given.Count) ? DefaultSources() : given;

            foreach (var src in list)
            {
                var kind = Types.Str(Types.Get(src, "kind"));
                if ("module" == kind)
                {
                    var prefixes = Types.List(Types.Get(src, "prefix"));
                    if (null == prefixes || 0 == prefixes.Count)
                    {
                        prefixes = new List<object> { "" };
                    }
                    foreach (var p in prefixes)
                    {
                        var id = Types.Str(p) + name;
                        if (!out_.Contains(id))
                        {
                            out_.Add(id);
                        }
                    }
                }
                else if ("path" == kind)
                {
                    var dir = Types.Str(Types.Get(src, "dir")) ?? "";
                    dir = dir.TrimEnd('/');
                    var id = dir + "/" + name;
                    if (!out_.Contains(id))
                    {
                        out_.Add(id);
                    }
                }
            }

            return out_;
        }

        /// <summary>
        /// A MODULE PATH IS NOT A NAME (§10.2). The ref grammar starts a
        /// name with a letter or <c>@</c>, so <c>./local/thing</c> is not
        /// a ref and never reaches candidate generation - seneca allows a
        /// path where a plugin name goes, and this design deliberately
        /// does not, because a ref is an ADDRESS WITHIN A HOST and a path
        /// is a LOCATION ON A DISK.
        /// </summary>
        public static List<object> ResolveFrom(object from)
        {
            return new List<object> { from };
        }
    }
}
