// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (csharp/src/Version.cs)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
using System;
using System.Collections.Generic;
using System.Globalization;

namespace Voxgig.Plugin
{
    /// <summary>
    /// Versions and ranges (§11.2).
    ///
    /// <para>TWO FIELDS AND ONE PREDICATE. A capability declares
    /// <c>version</c>, a concrete version. A requirement declares
    /// <c>range</c>. A requirement is satisfied when the names match, the
    /// <c>match</c> passes, and the provider's <c>version</c> falls inside
    /// the requirement's <c>range</c>.</para>
    ///
    /// <para>That is the whole rule. There is no third field and no second
    /// comparison - an earlier draft added a provider-side <c>compat</c>
    /// range, which left three values and no statement of how they
    /// combine, and three defensible readings of one declaration is worse
    /// than the ambiguity it was introduced to fix.</para>
    /// </summary>
    public static class Version
    {
        /// <summary>
        /// A COMPONENT IS BOUNDED, and the bound is the model's, not the
        /// host language's. Csharp's <c>long</c> and JavaScript's
        /// <c>Number</c> disagree past 2**53, so a twenty-digit component
        /// parsed to an exact value in one and a rounded one in the other.
        /// 2**31-1 is the smallest bound every target language holds
        /// exactly, which makes it the model's.
        /// </summary>
        public const long COMPONENT_MAX = 2147483647L;

        private static long Component(string digits, string whole, string field)
        {
            // Too long for a long is out of range by definition - the parse
            // failure and the bound check are the same answer, so they give
            // the same code.
            if (!long.TryParse(digits, NumberStyles.None, CultureInfo.InvariantCulture, out var value))
            {
                value = COMPONENT_MAX + 1;
            }
            if (COMPONENT_MAX < value)
            {
                Types.Fail("plugin_bad_range",
                           "version component out of range in " + whole + ": " + digits,
                           Types.Details(field, whole));
            }
            return value;
        }

        /// <summary>
        /// <c>1</c>, <c>1.2</c> or <c>1.2.3</c>, fully anchored - and
        /// there is no regex here, so "anchored" is what the code does
        /// rather than what an engine was asked for.
        /// </summary>
        private static long[] Parts(string text, string whole, string field)
        {
            var pieces = text.Split('.');
            if (0 == pieces.Length || 3 < pieces.Length)
            {
                return null;
            }
            var out_ = new long[] { 0, 0, 0 };
            for (var i = 0; i < pieces.Length; i++)
            {
                var piece = pieces[i];
                if (0 == piece.Length)
                {
                    return null;
                }
                foreach (var c in piece)
                {
                    if (c < '0' || '9' < c)
                    {
                        return null;
                    }
                }
                out_[i] = Component(piece, whole, field);
            }
            return out_;
        }

        /// <summary>
        /// Two forms and no more (§11.2): <c>'2.1'</c> is &gt;= 2.1.0 and
        /// &lt; 3.0.0; <c>'~2.1'</c> is &gt;= 2.1.0 and &lt; 2.2.0.
        /// </summary>
        public static SortedDictionary<string, object> ParseRange(object range)
        {
            var text = Types.Str(range);
            if (null == text || 0 == text.Length)
            {
                Types.Fail("plugin_bad_range", "invalid range: " + Json.Write(range),
                           Types.Details("range", range));
            }

            var tilde = text.StartsWith("~", StringComparison.Ordinal);
            var body = tilde ? text.Substring(1) : text;
            var got = Parts(body, text, "range");
            if (null == got)
            {
                Types.Fail("plugin_bad_range", "invalid range: " + text,
                           Types.Details("range", range));
            }

            var lo = new List<object> { (double)got[0], (double)got[1], (double)got[2] };
            var hi = tilde
                ? new List<object> { (double)got[0], (double)(got[1] + 1), 0.0 }
                : new List<object> { (double)(got[0] + 1), 0.0, 0.0 };

            var out_ = Types.NewMap();
            out_["lo"] = lo;
            out_["hi"] = hi;
            return out_;
        }

        public static long[] ParseVersion(object version)
        {
            var text = Types.Str(version);
            if (null == text)
            {
                Types.Fail("plugin_bad_range", "invalid version: " + Json.Write(version),
                           Types.Details("version", version));
            }
            var got = Parts(text, text, "version");
            if (null == got)
            {
                Types.Fail("plugin_bad_range", "invalid version: " + text,
                           Types.Details("version", version));
            }
            return got;
        }

        /// The one satisfaction predicate: lo &lt;= version &lt; hi.
        public static bool Satisfies(object version, object range)
        {
            var v = ParseVersion(version);
            var r = ParseRange(range);
            return 0 <= Compare(v, Triple(r["lo"])) && 0 > Compare(v, Triple(r["hi"]));
        }

        /// <summary>
        /// Satisfies for the internal callers that treat an unparseable
        /// version or range as "does not satisfy" - Capability and Graph,
        /// both of which run over data the corpus has already admitted.
        /// </summary>
        public static bool SatisfiesQ(object version, object range)
        {
            try
            {
                return Satisfies(version, range);
            }
            catch (PluginException)
            {
                return false;
            }
        }

        private static long[] Triple(object value)
        {
            var out_ = new long[3];
            for (var i = 0; i < 3; i++)
            {
                var n = Types.Num(Types.At(value, i));
                out_[i] = null == n ? 0 : (long)n.Value;
            }
            return out_;
        }

        private static int Compare(long[] a, long[] b)
        {
            for (var i = 0; i < 3; i++)
            {
                if (a[i] != b[i])
                {
                    return a[i] < b[i] ? -1 : 1;
                }
            }
            return 0;
        }

        /// The version triple as a comparable key, for the capability rank.
        public static List<long> VersionParts(string text)
        {
            var out_ = new List<long>();
            foreach (var piece in text.Split('.'))
            {
                out_.Add(long.TryParse(piece, NumberStyles.None, CultureInfo.InvariantCulture, out var n) ? n : 0);
            }
            return out_;
        }
    }
}
