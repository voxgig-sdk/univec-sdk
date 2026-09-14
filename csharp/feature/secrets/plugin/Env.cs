// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (csharp/src/Env.cs)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
using System;
using System.Collections.Generic;
using System.Globalization;

namespace Voxgig.Plugin
{
    /// <summary>
    /// Environment overrides (§9.5) - level 7 of the ladder. One prefix,
    /// so nothing drifts: <c>VOXGIG_PLUGIN_*</c>.
    ///
    /// <para>THE ENCODING IS LOSSY, AND THIS SAYS SO RATHER THAN
    /// PRETENDING OTHERWISE. Ref and path are upper-snake with <c>$</c>
    /// -&gt; <c>__</c> and <c>.</c> -&gt; <c>_</c>. But <c>_</c> is legal
    /// in a name and in a tag, and the mapping folds case, so
    /// <c>retry$fast</c> and <c>retry__fast</c> both encode to
    /// <c>RETRY__FAST</c>. Rather than restrict a grammar the rest of the
    /// stack already uses, the host DETECTS THE COLLISION.</para>
    /// </summary>
    public static class Env
    {
        public const string ENV_PREFIX = "VOXGIG_PLUGIN_";

        /// <summary>
        /// <c>retry$fast</c> -&gt; <c>RETRY__FAST</c>. INVARIANT casing:
        /// the Turkish dotless i would otherwise fold `I` to `ı` on a
        /// machine whose culture says so, and a ref would stop matching
        /// its own environment variable.
        /// </summary>
        public static string EncodeRef(string eref)
        {
            return eref.Replace("$", "__").Replace(".", "_").ToUpperInvariant();
        }

        public static SortedDictionary<string, object> ApplyEnv(object input)
        {
            var env = Types.Get(input, "env");
            var reserved = Types.Get(input, "reserved");

            var refs = new List<string>();
            var given = Types.List(Types.Get(input, "refs"));
            if (null != given)
            {
                foreach (var r in given)
                {
                    refs.Add(Refs.CanonRef(r));
                }
            }

            var options = Types.NewMap();
            var active = new List<object>();
            var inactive = new List<object>();
            var out_ = Types.NewMap();
            out_["options"] = options;
            out_["active"] = active;
            out_["inactive"] = inactive;

            // Encode every ref the host holds, and refuse a key that two of
            // them claim. Done up front so the collision is reported even
            // when no environment variable exercises it - a latent
            // ambiguity is still an ambiguity, and finding it at deploy
            // time is the failure this exists to prevent.
            var byencoded = new SortedDictionary<string, List<string>>(StringComparer.Ordinal);
            foreach (var r in refs)
            {
                var e = EncodeRef(r);
                if (!byencoded.TryGetValue(e, out var list))
                {
                    list = new List<string>();
                    byencoded[e] = list;
                }
                list.Add(r);
            }
            foreach (var pair in byencoded)
            {
                if (pair.Value.Count <= 1)
                {
                    continue;
                }
                var collide = new List<string>(pair.Value);
                Types.SortStrings(collide);
                Types.Fail("plugin_env_ambiguous",
                           "refs collide in the environment encoding as " + pair.Key + ": "
                           + string.Join(", ", collide),
                           Types.Details("refs", Types.Strings(collide)));
            }

            // Longest encoded ref first, so `retry$fast` wins over `retry`
            // on `RETRY__FAST_MIN`. Shortest-first would read the tag as a
            // path.
            var encoded = Types.StableSorted(new List<string>(byencoded.Keys),
                                             (a, b) => b.Length.CompareTo(a.Length));

            foreach (var key in Types.Keys(env))
            {
                if (!key.StartsWith(ENV_PREFIX, StringComparison.Ordinal))
                {
                    continue;
                }
                var rest = key.Substring(ENV_PREFIX.Length);

                if ("PROFILE" == rest)
                {
                    out_["profile"] = Types.Get(env, key);
                    continue;
                }

                if ("ACTIVE" == rest || "INACTIVE" == rest)
                {
                    var target = "ACTIVE" == rest ? active : inactive;
                    foreach (var raw in Split(Types.Get(env, key)))
                    {
                        var eref = Refs.CanonRef(raw);
                        // The reservation covers EVERY input layer (§9.1).
                        // VOXGIG_PLUGIN_INACTIVE=station is easier to set
                        // than editing a config file, and INACTIVE has the
                        // final word - so guarding documents alone would
                        // leave the one lever this mechanism exists to
                        // deny wide open.
                        CheckReserved(eref, reserved);
                        target.Add(eref);
                    }
                    continue;
                }

                string enc = null;
                foreach (var e in encoded)
                {
                    if (rest == e || rest.StartsWith(e + "_", StringComparison.Ordinal))
                    {
                        enc = e;
                        break;
                    }
                }
                if (null == enc)
                {
                    continue; // not for any ref this host holds
                }

                var target_ref = byencoded[enc][0];
                CheckReserved(target_ref, reserved);

                if (rest == enc)
                {
                    continue; // a ref with no path sets nothing
                }

                var path = rest.Substring(enc.Length + 1).ToLowerInvariant().Split('_');

                if (null == Types.Map(Types.Get(options, target_ref)))
                {
                    options[target_ref] = Types.NewMap();
                }
                var node = Types.Map(options[target_ref]);
                for (var i = 0; i < path.Length - 1; i++)
                {
                    if (null == Types.Map(Types.Get(node, path[i])))
                    {
                        node[path[i]] = Types.NewMap();
                    }
                    node = Types.Map(node[path[i]]);
                }
                node[path[path.Length - 1]] = ParseValue(Types.Get(env, key));
            }

            return out_;
        }

        private static List<string> Split(object value)
        {
            var out_ = new List<string>();
            var text = Types.Str(value);
            if (null == text)
            {
                return out_;
            }
            foreach (var part in text.Split(','))
            {
                var trimmed = part.Trim();
                if (0 < trimmed.Length)
                {
                    out_.Add(trimmed);
                }
            }
            return out_;
        }

        private static void CheckReserved(string eref, object reserved)
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

        /// <summary>
        /// Values parse as JSON, FALLING BACK TO STRING - so <c>8080</c>
        /// is a number, <c>true</c> is a boolean, <c>{"a":1}</c> is a map,
        /// and <c>hello</c> is the string it looks like rather than a
        /// parse error.
        /// </summary>
        private static object ParseValue(object value)
        {
            var text = Types.Str(value);
            if (null == text)
            {
                return value;
            }
            try
            {
                return Json.Parse(text);
            }
            catch (Exception)
            {
                return value;
            }
        }
    }
}
