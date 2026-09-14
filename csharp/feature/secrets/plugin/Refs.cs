// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (csharp/src/Refs.cs)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
using System;
using System.Collections.Generic;

namespace Voxgig.Plugin
{
    /// <summary>
    /// Identity: name+tag, written <c>name$tag</c> (§4).
    ///
    /// <para>The four pure functions, and the whole of what <c>ref</c>
    /// pins. They are the first thing a new port implements and the first
    /// corpus section it passes.</para>
    ///
    /// <para>NO REGEX. <c>System.Text.RegularExpressions</c>' <c>$</c>
    /// matches before a final <c>\n</c>, so a <c>^...$</c> spelling would
    /// admit <c>"stripe\n"</c> as a name - the hole the ruby port surfaced
    /// in python. A character-class walk cannot have it, and the four
    /// <c>#trailing-newline</c> entries pass here without the port having
    /// to know they exist.</para>
    /// </summary>
    public static class Refs
    {
        public const int REF_MAX = 1024;

        /// §4: <c>^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$</c>, max 1024.
        public static bool CheckName(object name)
        {
            var text = Types.Str(name);
            if (null == text || 0 == text.Length || REF_MAX < text.Length)
            {
                return false;
            }
            var first = text[0];
            if (!IsAlpha(first) && '@' != first)
            {
                return false;
            }
            for (var i = 1; i < text.Length; i++)
            {
                var c = text[i];
                if (!IsAlpha(c) && !IsDigit(c)
                    && '.' != c && '~' != c && '_' != c && '-' != c && '/' != c)
                {
                    return false;
                }
            }
            return true;
        }

        /// <summary>
        /// §4: <c>^[a-zA-Z0-9.~_-]+$</c>, max 1024, or empty.
        ///
        /// <para>The asymmetry with a name is deliberate: a tag MAY start
        /// with a digit because auto-tagging assigns integer tags
        /// (<c>stripe$1</c>), and a tag admits neither <c>@</c> nor
        /// <c>/</c> because a name is a package specifier and a tag is
        /// not.</para>
        /// </summary>
        public static bool CheckTag(object tag)
        {
            var text = Types.Str(tag);
            if (null == text)
            {
                return false;
            }
            // The empty tag is an ordinary tag (§4 rule 2). The
            // single-instance case writes no tag and never learns tags
            // exist.
            if (0 == text.Length)
            {
                return true;
            }
            if (REF_MAX < text.Length)
            {
                return false;
            }
            foreach (var c in text)
            {
                if (!IsAlpha(c) && !IsDigit(c) && '.' != c && '~' != c && '_' != c && '-' != c)
                {
                    return false;
                }
            }
            return true;
        }

        private static bool IsAlpha(char c)
        {
            return ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z');
        }

        private static bool IsDigit(char c)
        {
            return '0' <= c && c <= '9';
        }

        /// <summary>
        /// <c>name$tag</c> -&gt; the pair. Canonicalizing: <c>stripe$</c>
        /// and <c>stripe</c> both give tag "".
        /// </summary>
        public static SortedDictionary<string, object> ParseRef(object value)
        {
            var text = Types.Str(value);
            if (null == text)
            {
                Types.Fail("plugin_bad_name", "ref must be a string", null);
            }

            // Split on the FIRST `$`. Nothing in the grammar decides this -
            // `$` is in neither character class - so the corpus is the
            // arbiter (§4 rule 5), and it picks the split that blames the
            // part actually at fault: `a$b$c` is a good name with a bad
            // tag, not the reverse.
            var cut = text.IndexOf('$');
            var name = cut < 0 ? text : text.Substring(0, cut);
            var tag = cut < 0 ? "" : text.Substring(cut + 1);

            if (!CheckName(name))
            {
                Types.Fail("plugin_bad_name", "invalid plugin name: " + name,
                           Types.Details("name", name));
            }
            if (!CheckTag(tag))
            {
                Types.Fail("plugin_bad_tag", "invalid plugin tag: " + tag,
                           Types.Details("name", name, "tag", tag));
            }

            var out_ = Types.NewMap();
            out_["name"] = name;
            out_["tag"] = tag;
            return out_;
        }

        /// <summary>
        /// The pair -&gt; <c>name$tag</c>. An empty tag NEVER writes the
        /// separator, which is the half of canonicalization this owns:
        /// parse tolerates <c>stripe$</c>, format never produces it, so a
        /// round trip is idempotent.
        /// </summary>
        public static string FormatRef(object name, object tag)
        {
            var usetag = null == tag ? "" : tag;
            if (!CheckName(name))
            {
                Types.Fail("plugin_bad_name", "invalid plugin name: " + Json.Write(name),
                           Types.Details("name", name));
            }
            if (!CheckTag(usetag))
            {
                Types.Fail("plugin_bad_tag", "invalid plugin tag: " + Json.Write(usetag),
                           Types.Details("name", name, "tag", usetag));
            }
            var text = Types.Str(usetag);
            return 0 == text.Length ? Types.Str(name) : Types.Str(name) + "$" + text;
        }

        /// The canonical spelling of a ref. §4 rule 5: ports must
        /// canonicalize before comparison.
        public static string CanonRef(object value)
        {
            var parsed = ParseRef(value);
            return FormatRef(parsed["name"], parsed["tag"]);
        }

        /// <summary>
        /// CanonRef for the internal callers that want the input back
        /// unchanged when it is not well formed. NEVER use it where a bad
        /// ref must be reported - the corpus pins plugin_bad_name at every
        /// public entry.
        /// </summary>
        public static string Canon(string text)
        {
            try
            {
                return CanonRef(text);
            }
            catch (PluginException)
            {
                return text;
            }
        }

        public static string RefName(string text)
        {
            try
            {
                return Types.Str(ParseRef(text)["name"]);
            }
            catch (PluginException)
            {
                return text;
            }
        }
    }
}
