// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (csharp/src/Config.cs)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
using System;
using System.Collections.Generic;

namespace Voxgig.Plugin
{
    /// <summary>
    /// The declarative document (§9): normalization, and the ten-level
    /// precedence ladder.
    ///
    /// <para>TWO FUNCTIONS, AND THE SPLIT BETWEEN THEM IS FORCED.
    /// <c>NormalizeConfig</c> normalizes STRUCTURE and ENTRY KEYS. It does
    /// not merge options, and cannot: §9.4 makes merge behaviour a
    /// property of the definition's option SHAPE, which normalization has
    /// never seen. A normalizer that flattened the option layers would
    /// make <c>$MERGE: append</c> unimplementable at load time, because
    /// the layers it must concatenate would already be
    /// collapsed.</para>
    ///
    /// <para><c>ResolveOptions</c> applies the ladder, and it is the only
    /// place that knows the shape.</para>
    /// </summary>
    public static class Config
    {
        public static readonly string[] MERGE_WORDS = { "replace", "append" };

        public static SortedDictionary<string, object> NormalizeConfig(object input)
        {
            var doc = Types.Get(input, "doc");
            var keys = Types.Get(input, "keys");
            var ikey = Types.Str(Types.Get(keys, "instance")) ?? "instance";
            var dkey = Types.Str(Types.Get(keys, "default")) ?? "default";
            var reserved = Types.Get(input, "reserved");
            var profile = Types.Get(input, "profile");

            // The rename is applied at TWO PLACES AND NO OTHERS: the
            // document root, and every profile.<name> overlay root (§9.1).
            // A rename applied only at the root would leave
            // `profile.prod.sdk` untranslated and silently drop every
            // environment override the host depends on. Recursing further
            // would be worse: option data is the definition's.
            var baseinst = Types.Get(doc, ikey);
            var basedef = Types.Get(doc, dkey);

            object overlay = null == Types.Str(profile)
                ? null
                : Types.Get(Types.Get(doc, "profile"), Types.Str(profile));
            if (null == Types.Map(overlay))
            {
                overlay = Types.NewMap();
            }
            var overinst = Types.Get(overlay, ikey);
            var overdef = Types.Get(overlay, dkey);

            var baseentries = Entries(baseinst);
            var overentries = Entries(overinst);

            var groups = new List<List<string>>
            {
                new List<string>(baseentries.Map.Keys),
                new List<string>(overentries.Map.Keys),
                Types.Keys(basedef),
                Types.Keys(overdef),
            };
            foreach (var group in groups)
            {
                foreach (var r in group)
                {
                    CheckReserved(r, reserved);
                }
            }

            // A PARTIAL ARRAY IS NOT A FILTER (§9.1). sdkgen learned this
            // the hard way: deriving order from a partial array silently
            // dropped config-activated features. Refs in the base but
            // absent from the overlay still load, in sorted position AFTER
            // the listed ones. A profile may also INTRODUCE a ref the base
            // never declared.
            var order = new List<string>();
            foreach (var r in overentries.Order)
            {
                if (!order.Contains(r))
                {
                    order.Add(r);
                }
            }
            foreach (var r in baseentries.Order)
            {
                if (!order.Contains(r))
                {
                    order.Add(r);
                }
            }

            var instance = Types.NewMap();
            for (var i = 0; i < order.Count; i++)
            {
                var eref = order[i];
                baseentries.Map.TryGetValue(eref, out var b);
                overentries.Map.TryGetValue(eref, out var o);

                // MERGE THE ENTRIES AS AUTHORED, THEN APPLY DEFAULTS TO
                // THE RESULT (§9.3). A safety rule, not a tidiness one: if
                // the overlay had its defaults filled in before merging it
                // would carry a synthesized active:true and overwrite a
                // base's false - silently re-enabling a deliberately
                // disabled integration in production.
                var active = Pick(o, "active", Pick(b, "active", true));
                var start = Pick(o, "start", Pick(b, "start", "eager"));
                var block = Pick(o, "order", Pick(b, "order", null));

                // Option layers, levels 3-6, IN LADDER ORDER. Never merged
                // here.
                var nm = Refs.RefName(eref);
                var layers = new List<object>();
                var sources = new List<object>
                {
                    Types.Get(basedef, nm), b, Types.Get(overdef, nm), o,
                };
                foreach (var src in sources)
                {
                    if (Types.Has(src, "options"))
                    {
                        layers.Add(Types.Get(src, "options"));
                    }
                }

                var ent = Types.NewMap();
                ent["pos"] = (double)i;
                ent["active"] = active;
                ent["start"] = start;
                ent["optionlayers"] = layers;
                if (null != block)
                {
                    ent["order"] = block;
                }
                instance[eref] = ent;
            }

            // `default` DECLARES NOTHING (§9.3). It is a base for every
            // instance of that definition; it does not create one, and an
            // entry for a name with no instances is inert rather than an
            // error - which is what makes a shared library of defaults
            // shippable.
            var defout = Types.NewMap();
            foreach (var n in Types.Keys(basedef))
            {
                defout[n] = Types.Get(basedef, n);
            }
            foreach (var n in Types.Keys(overdef))
            {
                defout[n] = Types.Get(overdef, n);
            }

            var out_ = Types.NewMap();
            out_["instance"] = instance;
            out_["order"] = Types.Strings(order);
            out_["default"] = defout;
            return out_;
        }

        private sealed class EntrySet
        {
            public readonly SortedDictionary<string, object> Map =
                new SortedDictionary<string, object>(StringComparer.Ordinal);

            public readonly List<string> Order = new List<string>();
        }

        /// <summary>
        /// Both document forms reduce to {ref -&gt; entry} plus the order
        /// the form implies: array POSITION for the array form, sorted
        /// refs for the map form.
        /// </summary>
        private static EntrySet Entries(object src)
        {
            var out_ = new EntrySet();
            if (null == src)
            {
                return out_;
            }

            var items = Types.List(src);
            if (null != items)
            {
                foreach (var item in items)
                {
                    var eref = Refs.CanonRef(Types.Get(item, "ref"));
                    out_.Map[eref] = item;
                    out_.Order.Add(eref);
                }
                return out_;
            }

            // Map-form refs arrive as KEYS, through a different path than
            // an array element's `ref` field - and must canonicalize the
            // same way.
            foreach (var key in Types.Keys(src))
            {
                out_.Map[Refs.CanonRef(key)] = Types.Get(src, key);
            }
            // Byte-wise, NOT locale-aware and NOT case-folded. The map is
            // ORDINALLY sorted for exactly this reason (Types.NewMap says
            // why at length).
            out_.Order.AddRange(out_.Map.Keys);
            return out_;
        }

        /// <summary>
        /// §9.1: reservation is all-or-nothing per NAME, so the tagged
        /// forms go too. A configuration surface that can disable the
        /// thing reading it is not a surface, it is a trap.
        /// </summary>
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
        /// PRESENCE decides, not truthiness and not null. A JSON
        /// <c>null</c> is a present value in JavaScript (<c>undefined !==
        /// null</c>), so it must be one here.
        /// </summary>
        private static object Pick(object src, string key, object dflt)
        {
            return Types.Has(src, key) ? Types.Get(src, key) : dflt;
        }

        // ---------------------------------------------------------------
        // ResolveOptions - §9.3's ten levels, and 9.4's directives
        // ---------------------------------------------------------------

        public static SortedDictionary<string, object> ResolveOptions(object input)
        {
            var shape = Types.Get(input, "shape");
            CheckShape(shape);

            var eref = Refs.CanonRef(Types.Get(input, "ref"));
            var name = Refs.RefName(eref);
            var doc = Types.Get(input, "doc");
            var profile = Types.Get(input, "profile");

            object overlay = null == Types.Str(profile)
                ? null
                : Types.Get(Types.Get(doc, "profile"), Types.Str(profile));
            if (null == Types.Map(overlay))
            {
                overlay = Types.NewMap();
            }

            // ONE ordered merge, lowest to highest. Levels 3-6 are not two
            // namespaces collapsed separately and composed afterwards:
            // that inverts the rule that PROFILE SPECIFICITY OUTRANKS
            // DEFINITION SPECIFICITY, so a prod per-definition default
            // would lose to a base instance value.
            var layers = new List<object>
            {
                DefaultsOf(shape),                                       // 1
                Types.Get(input, "hostdefaults"),                        // 2
                OptsOf(Types.Get(doc, "default"), name),                 // 3
                OptsOf(Types.Get(doc, "instance"), eref),                // 4
                OptsOf(Types.Get(overlay, "default"), name),             // 5
                OptsOf(Types.Get(overlay, "instance"), eref),            // 6
                Types.Get(input, "env"),                                 // 7
                Types.Get(input, "hostoptions"),                         // 8
                Types.Get(input, "loadoptions"),                         // 9
                Types.Get(input, "patch"),                               // 10
            };

            object out_ = Types.NewMap();
            foreach (var layer in layers)
            {
                if (null == layer)
                {
                    continue;
                }
                out_ = MergeOne(out_, layer, shape);
            }
            return Types.Map(out_);
        }

        /// The shape's non-directive values are the level-1 defaults.
        private static SortedDictionary<string, object> DefaultsOf(object shape)
        {
            var out_ = Types.NewMap();
            foreach (var k in Types.Keys(shape))
            {
                var v = Types.Get(shape, k);
                if (Types.Has(v, "$MERGE"))
                {
                    continue;
                }
                out_[k] = v;
            }
            return out_;
        }

        private static object OptsOf(object src, string key)
        {
            if (null == src)
            {
                return null;
            }

            // The array form is equivalent to the map form (§9.1).
            var items = Types.List(src);
            if (null != items)
            {
                foreach (var item in items)
                {
                    if (Refs.CanonRef(Types.Get(item, "ref")) == key)
                    {
                        return Types.Get(item, "options");
                    }
                }
                return null;
            }

            foreach (var k in Types.Keys(src))
            {
                if (Refs.CanonRef(k) != key)
                {
                    continue;
                }
                var entry = Types.Get(src, k);
                return null == Types.Map(entry) ? null : Types.Get(entry, "options");
            }
            return null;
        }

        /// <summary>
        /// Merge ONE layer onto the accumulator, honouring the shape's
        /// directives. The directive holds at EVERY precedence level, not
        /// only between document levels - §9.4 makes it a property of the
        /// shape, which does not know which layer a value arrived from.
        /// </summary>
        private static object MergeOne(object base_, object over, object shape)
        {
            if (null == over)
            {
                return base_;
            }
            var b = Types.Map(base_);
            var o = Types.Map(over);
            if (null == b || null == o)
            {
                return Types.Copy(over);
            }

            var out_ = Types.NewMap();
            foreach (var pair in b)
            {
                out_[pair.Key] = pair.Value;
            }

            foreach (var k in Types.Keys(o))
            {
                var ov = Types.Get(o, k);
                var directive = Types.Get(Types.Get(shape, k), "$MERGE");
                out_.TryGetValue(k, out var bv);

                if ("replace".Equals(directive))
                {
                    out_[k] = Types.Copy(ov);
                }
                else if ("append".Equals(directive))
                {
                    var merged = new List<object>();
                    var bl = Types.List(bv);
                    if (null != bl)
                    {
                        merged.AddRange(bl);
                    }
                    var ol = Types.List(ov);
                    if (null == ol)
                    {
                        merged.Add(ov);
                    }
                    else
                    {
                        merged.AddRange(ol);
                    }
                    out_[k] = merged;
                }
                else if (Types.Has(directive, "deep"))
                {
                    out_[k] = DeepTo(bv, ov, Types.Get(directive, "deep"));
                }
                else
                {
                    // Library default: deep for maps, REPLACE for lists.
                    // struct.merge is element-wise by index, which for
                    // option maps is nearly always wrong - ["a"] over
                    // ["x","y","z"] yielding ["a","y","z"] is the defect
                    // station hit on secrets.providers.
                    if (null != Types.Map(bv) && null != Types.Map(ov))
                    {
                        out_[k] = MergeOne(bv, ov, null);
                    }
                    else
                    {
                        out_[k] = Types.Copy(ov);
                    }
                }
            }
            return out_;
        }

        /// Merge N levels below this key, replace below that.
        private static object DeepTo(object base_, object over, object depth)
        {
            var n = Types.Num(depth);
            if (null == n || n <= 0)
            {
                return Types.Copy(over);
            }
            var b = Types.Map(base_);
            var o = Types.Map(over);
            if (null == b || null == o)
            {
                return Types.Copy(over);
            }
            var out_ = Types.NewMap();
            foreach (var pair in b)
            {
                out_[pair.Key] = pair.Value;
            }
            foreach (var k in Types.Keys(o))
            {
                out_.TryGetValue(k, out var below);
                out_[k] = DeepTo(below, Types.Get(o, k), n.Value - 1);
            }
            return out_;
        }

        /// <summary>
        /// §9.4: N is an integer of at least 1, and everything else is an
        /// error. <c>{"deep": 0}</c> is rejected DESPITE having an obvious
        /// reading, because "replace at this key" already has a spelling
        /// and two spellings for one behaviour is the defect class this
        /// repo exists to avoid.
        /// </summary>
        public static void CheckShape(object shape)
        {
            if (null == Types.Map(shape))
            {
                return;
            }

            foreach (var k in Types.Keys(shape))
            {
                var v = Types.Get(shape, k);
                if (!Types.Has(v, "$MERGE"))
                {
                    continue;
                }
                var directive = Types.Get(v, "$MERGE");

                var word = Types.Str(directive);
                if (null != word)
                {
                    if (Array.IndexOf(MERGE_WORDS, word) >= 0)
                    {
                        continue;
                    }
                    Types.Fail("plugin_shape_invalid",
                               "invalid $MERGE directive at " + k + ": " + word,
                               Types.Details("key", k));
                }

                if (Types.Has(directive, "deep"))
                {
                    var n = Types.Get(directive, "deep");
                    // `AsInt` is double-and-integral: `true` is a bool and
                    // `"2"` a string, so the type test the dynamic ports
                    // need is this call.
                    var asint = Types.AsInt(n);
                    if (null != asint && 1 <= asint.Value)
                    {
                        continue;
                    }
                    Types.Fail("plugin_shape_invalid",
                               "invalid $MERGE deep at " + k + ": " + Json.Write(n),
                               Types.Details("key", k));
                }

                Types.Fail("plugin_shape_invalid",
                           "invalid $MERGE directive at " + k + ": " + Json.Write(directive),
                           Types.Details("key", k));
            }
        }
    }
}
