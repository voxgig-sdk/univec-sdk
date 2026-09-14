// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (csharp/src/Types.cs)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
using System;
using System.Collections.Generic;
using System.Globalization;

namespace Voxgig.Plugin
{
    /// <summary>
    /// Shared types and the value helpers every module reads data through.
    ///
    /// <para>Deliberately small: the design's §19 budget says the library
    /// owns naming, configuration, lifecycle, ordering, binding and
    /// teardown, and nothing else.</para>
    ///
    /// <para>THE VALUE MODEL IS PLAIN <c>object</c>, with ONE csharp
    /// spelling per JSON type: <c>null</c>, <c>bool</c>, <c>double</c>,
    /// <c>string</c>, <c>List&lt;object&gt;</c> and a
    /// <c>SortedDictionary&lt;string,object&gt;</c> ordered
    /// <c>Ordinal</c>. Two of those choices are corpus-visible and both
    /// are explained where they are made: every number is a double, and
    /// every string comparison is ordinal.</para>
    /// </summary>
    public static class Types
    {
        /// §5.1's seven statuses, and no more. A port that adds an eighth
        /// is diverging.
        public static readonly string[] STATUSES =
        {
            "declared", "loaded", "pending", "live", "failed", "loading", "closing",
        };

        /// §12's detail fields, IN THIS FIXED ORDER. The order is part of
        /// the contract, not a formatting preference: an earlier draft
        /// named six fields while other sections promised diagnostics that
        /// had nowhere to go, which would have left each port inventing
        /// its own order and breaking message parity.
        public static readonly string[] DETAIL_ORDER =
        {
            "host", "ref", "name", "tag", "point", "key", "capability", "range",
            "version", "match", "candidates", "cycle", "holders", "refs", "path", "cause",
        };

        /// <summary>
        /// A map, ORDINALLY sorted.
        ///
        /// <para>NOT the default comparer. <c>Comparer&lt;string&gt;.Default</c>
        /// is CULTURE-SENSITIVE, so `"a"` before `"B"` in one locale and
        /// after it in another - and this port sorts refs, keys and names
        /// for exactly the reason every other port does: the corpus pins a
        /// byte-wise order (`@` 0x40, uppercase, lowercase). A culture
        /// comparer is a port that passes on the build machine.</para>
        /// </summary>
        public static SortedDictionary<string, object> NewMap()
        {
            return new SortedDictionary<string, object>(StringComparer.Ordinal);
        }

        public static SortedDictionary<string, object> Map(object value)
        {
            return value as SortedDictionary<string, object>;
        }

        public static List<object> List(object value)
        {
            return value as List<object>;
        }

        public static string Str(object value)
        {
            return value as string;
        }

        public static double? Num(object value)
        {
            return value is double d ? d : (double?)null;
        }

        /// <summary>
        /// An INTEGER, and only when the value is one. §7's band is an
        /// integer the document wrote as one; <c>true</c> and <c>"2"</c>
        /// are not bands, and a port that coerced them would accept
        /// documents the canonical rejects.
        /// </summary>
        public static long? AsInt(object value)
        {
            if (!(value is double d) || d != Math.Floor(d) || double.IsInfinity(d))
            {
                return null;
            }
            return (long)d;
        }

        /// The value at a key, or null. Absence and null read the same here.
        public static object Get(object node, string key)
        {
            var map = Map(node);
            if (null == map)
            {
                return null;
            }
            return map.TryGetValue(key, out var value) ? value : null;
        }

        /// PRESENCE, which is what distinguishes an authored null from absence.
        public static bool Has(object node, string key)
        {
            var map = Map(node);
            return null != map && map.ContainsKey(key);
        }

        public static object At(object node, int index)
        {
            var list = List(node);
            return null == list || list.Count <= index ? null : list[index];
        }

        /// The keys of a map, sorted - which the map already is.
        public static List<string> Keys(object node)
        {
            var map = Map(node);
            var out_ = new List<string>();
            if (null == map)
            {
                return out_;
            }
            out_.AddRange(map.Keys);
            return out_;
        }

        /// <summary>
        /// Ruby's truthiness, which is not csharp's <c>if</c>: present,
        /// and not <c>false</c>. <c>0</c>, <c>""</c> and <c>[]</c> are all
        /// values the corpus distinguishes from absence.
        /// </summary>
        public static bool Truthy(object value)
        {
            return null != value && !(value is bool b && !b);
        }

        /// <summary>
        /// JSON equality: same type, then same value.
        ///
        /// <para><c>true</c> is not <c>1</c> and <c>1</c> is not
        /// <c>"1"</c> - `capability/match` has an entry for each
        /// direction. CSHARP NEEDS NO GUARD FOR THAT: a boxed bool and a
        /// boxed double are different types and <c>Equals</c> is false
        /// between them. What it DOES need is the one-number-type rule
        /// kept at the parser, because a boxed <c>int</c> would compare
        /// unequal to the <c>double</c> the parser produced for the same
        /// literal.</para>
        /// </summary>
        public static bool Same(object a, object b)
        {
            var ma = Map(a);
            var mb = Map(b);
            if (null != ma || null != mb)
            {
                if (null == ma || null == mb || ma.Count != mb.Count)
                {
                    return false;
                }
                foreach (var pair in ma)
                {
                    if (!mb.TryGetValue(pair.Key, out var other) || !Same(pair.Value, other))
                    {
                        return false;
                    }
                }
                return true;
            }

            var la = List(a);
            var lb = List(b);
            if (null != la || null != lb)
            {
                if (null == la || null == lb || la.Count != lb.Count)
                {
                    return false;
                }
                for (var i = 0; i < la.Count; i++)
                {
                    if (!Same(la[i], lb[i]))
                    {
                        return false;
                    }
                }
                return true;
            }

            return null == a ? null == b : a.Equals(b);
        }

        public static object Copy(object value)
        {
            var map = Map(value);
            if (null != map)
            {
                var out_ = NewMap();
                foreach (var pair in map)
                {
                    out_[pair.Key] = Copy(pair.Value);
                }
                return out_;
            }
            var list = List(value);
            if (null != list)
            {
                var out_ = new List<object>();
                foreach (var item in list)
                {
                    out_.Add(Copy(item));
                }
                return out_;
            }
            return value;
        }

        /// A list of strings as a list of values, for a detail field.
        public static List<object> Strings(IEnumerable<string> items)
        {
            var out_ = new List<object>();
            foreach (var s in items)
            {
                out_.Add(s);
            }
            return out_;
        }

        /// ORDINAL, for the same reason <see cref="NewMap"/> is.
        public static void SortStrings(List<string> items)
        {
            items.Sort(StringComparer.Ordinal);
        }

        /// <summary>
        /// A STABLE sort.
        ///
        /// <para><c>List&lt;T&gt;.Sort</c> is an INTROSORT and is NOT
        /// stable, and the canonical's comparators fall through to a
        /// `pos` or ref tie-break that javascript's stable sort resolves
        /// by position. So this decorates with the original index and
        /// breaks the last tie on it - the same shape ruby and lua need,
        /// for the same reason.</para>
        /// </summary>
        public static List<T> StableSorted<T>(List<T> items, Comparison<T> compare)
        {
            var source = items.ToArray();
            var order = new int[source.Length];
            for (var i = 0; i < order.Length; i++)
            {
                order[i] = i;
            }
            Array.Sort(order, (x, y) =>
            {
                var c = compare(source[x], source[y]);
                return 0 != c ? c : x.CompareTo(y);
            });
            var out_ = new List<T>(source.Length);
            foreach (var at in order)
            {
                out_.Add(source[at]);
            }
            return out_;
        }

        /// A detail map, spelled once rather than at forty call sites.
        public static SortedDictionary<string, object> Details(params object[] pairs)
        {
            var out_ = NewMap();
            for (var i = 0; i + 1 < pairs.Length; i += 2)
            {
                out_[(string)pairs[i]] = pairs[i + 1];
            }
            return out_;
        }

        /// <summary>
        /// <c>plugin/&lt;code&gt;: &lt;text&gt; [&lt;key&gt;=&lt;value&gt; ...]</c>
        ///
        /// <para>Values render as COMPACT JSON, so a value containing a
        /// space or a bracket cannot break the parse, and a list renders
        /// as a JSON array. The bracket is absent entirely when no field
        /// applies.</para>
        /// </summary>
        public static string FormatError(string code, string text, object details)
        {
            var parts = new List<string>();
            foreach (var key in DETAIL_ORDER)
            {
                if (!Has(details, key))
                {
                    continue;
                }
                parts.Add(key + "=" + Json.Write(Get(details, key)));
            }
            var tail = 0 == parts.Count ? "" : " [" + string.Join(" ", parts) + "]";
            return "plugin/" + code + ": " + text + tail;
        }

        /// Throw a §12 error. One spelling, so every raise site reads the same.
        public static void Fail(string code, string text, object details)
        {
            throw new PluginException(code, text, details);
        }

        /// <summary>
        /// The §12 code of an exception, or "" for one this library did
        /// not raise. The corpus compares by code, so the driver needs one
        /// place that knows how to read it.
        /// </summary>
        public static string CodeOf(Exception err)
        {
            return err is PluginException pe ? pe.Code : "";
        }

        /// Invariant formatting, so a number in a message never depends on
        /// the machine's locale.
        public static string NumText(double n)
        {
            if (n == Math.Floor(n) && !double.IsInfinity(n) && Math.Abs(n) < 1e15)
            {
                return ((long)n).ToString(CultureInfo.InvariantCulture);
            }
            return n.ToString("R", CultureInfo.InvariantCulture);
        }
    }

    /// <summary>
    /// Every error carries a §12 code. Ports compare by CODE and never by
    /// message: wording is a port's own business, and pinning the words
    /// would make every translation a corpus change. The FORMAT, however,
    /// is pinned - a parseable message is what makes a log searchable
    /// across twenty languages.
    /// </summary>
    public class PluginException : Exception
    {
        public readonly string Code;
        public readonly string Text;
        public readonly object Details;

        public PluginException(string code, string text, object details)
            : base(Types.FormatError(code, text, details))
        {
            Code = code;
            Text = text;
            Details = details;
        }
    }
}
