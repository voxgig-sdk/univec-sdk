// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (csharp/src/Json.cs)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace Voxgig.Plugin
{
    /// <summary>
    /// The JSON value model's parser and writer, and the only one this
    /// port has.
    ///
    /// <para>NO System.Text.Json AND NO NEWTONSOFT (§16). The library is
    /// allowed exactly one runtime dependency, <c>voxgig/struct</c>, which
    /// has no csharp port; everything else is the BCL, and a parser is two
    /// hundred lines. It also keeps `dotnet restore` with nothing to
    /// fetch, which is what makes `make test` work offline.</para>
    ///
    /// <para>A NUMBER IS ALWAYS A <c>double</c>, because JSON has one
    /// number type and the canonical is javascript. A boxed <c>int</c>
    /// anywhere in this data would compare unequal to the <c>double</c>
    /// the parser produced for the same literal, and the corpus would fail
    /// on a distinction the model does not have.</para>
    /// </summary>
    public static class Json
    {
        public static object Parse(string text)
        {
            var at = 0;
            SkipWs(text, ref at);
            var value = ParseValue(text, ref at);
            SkipWs(text, ref at);
            if (at < text.Length)
            {
                throw new ArgumentException("trailing input at " + at);
            }
            return value;
        }

        /// Compact JSON, map keys in sorted order (which the map already is).
        public static string Write(object value)
        {
            var out_ = new StringBuilder();
            WriteTo(value, out_);
            return out_.ToString();
        }

        private static void WriteTo(object value, StringBuilder out_)
        {
            if (null == value)
            {
                out_.Append("null");
                return;
            }
            if (value is bool b)
            {
                out_.Append(b ? "true" : "false");
                return;
            }
            if (value is double d)
            {
                out_.Append(Types.NumText(d));
                return;
            }
            if (value is string s)
            {
                WriteString(s, out_);
                return;
            }
            var list = Types.List(value);
            if (null != list)
            {
                out_.Append('[');
                for (var i = 0; i < list.Count; i++)
                {
                    if (0 < i)
                    {
                        out_.Append(',');
                    }
                    WriteTo(list[i], out_);
                }
                out_.Append(']');
                return;
            }
            var map = Types.Map(value);
            if (null != map)
            {
                out_.Append('{');
                var first = true;
                foreach (var pair in map)
                {
                    if (!first)
                    {
                        out_.Append(',');
                    }
                    first = false;
                    WriteString(pair.Key, out_);
                    out_.Append(':');
                    WriteTo(pair.Value, out_);
                }
                out_.Append('}');
                return;
            }
            // A host object published through `exports` (§11) - the library
            // never inspects one and nothing in the corpus compares one.
            out_.Append("\"(opaque)\"");
        }

        private static void WriteString(string text, StringBuilder out_)
        {
            out_.Append('"');
            foreach (var c in text)
            {
                switch (c)
                {
                    case '"': out_.Append("\\\""); break;
                    case '\\': out_.Append("\\\\"); break;
                    case '\n': out_.Append("\\n"); break;
                    case '\r': out_.Append("\\r"); break;
                    case '\t': out_.Append("\\t"); break;
                    default:
                        if (c < 0x20)
                        {
                            out_.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                        }
                        else
                        {
                            out_.Append(c);
                        }
                        break;
                }
            }
            out_.Append('"');
        }

        private static void SkipWs(string s, ref int at)
        {
            while (at < s.Length && (' ' == s[at] || '\t' == s[at] || '\n' == s[at] || '\r' == s[at]))
            {
                at++;
            }
        }

        private static object ParseValue(string s, ref int at)
        {
            if (s.Length <= at)
            {
                throw new ArgumentException("unexpected end of input");
            }
            switch (s[at])
            {
                case '{': return ParseMap(s, ref at);
                case '[': return ParseList(s, ref at);
                case '"': return ParseString(s, ref at);
                case 't': return Literal(s, ref at, "true", true);
                case 'f': return Literal(s, ref at, "false", false);
                case 'n': return Literal(s, ref at, "null", null);
                default: return ParseNumber(s, ref at);
            }
        }

        private static object Literal(string s, ref int at, string word, object value)
        {
            if (s.Length < at + word.Length || word != s.Substring(at, word.Length))
            {
                throw new ArgumentException("bad literal at " + at);
            }
            at += word.Length;
            return value;
        }

        private static object ParseMap(string s, ref int at)
        {
            var out_ = Types.NewMap();
            at++;
            SkipWs(s, ref at);
            if (at < s.Length && '}' == s[at])
            {
                at++;
                return out_;
            }
            while (true)
            {
                SkipWs(s, ref at);
                var key = ParseString(s, ref at);
                SkipWs(s, ref at);
                if (s.Length <= at || ':' != s[at])
                {
                    throw new ArgumentException("expected ':' at " + at);
                }
                at++;
                SkipWs(s, ref at);
                out_[key] = ParseValue(s, ref at);
                SkipWs(s, ref at);
                if (s.Length <= at)
                {
                    throw new ArgumentException("unexpected end in object");
                }
                if (',' == s[at])
                {
                    at++;
                    continue;
                }
                if ('}' == s[at])
                {
                    at++;
                    return out_;
                }
                throw new ArgumentException("expected ',' or '}' at " + at);
            }
        }

        private static object ParseList(string s, ref int at)
        {
            var out_ = new List<object>();
            at++;
            SkipWs(s, ref at);
            if (at < s.Length && ']' == s[at])
            {
                at++;
                return out_;
            }
            while (true)
            {
                SkipWs(s, ref at);
                out_.Add(ParseValue(s, ref at));
                SkipWs(s, ref at);
                if (s.Length <= at)
                {
                    throw new ArgumentException("unexpected end in array");
                }
                if (',' == s[at])
                {
                    at++;
                    continue;
                }
                if (']' == s[at])
                {
                    at++;
                    return out_;
                }
                throw new ArgumentException("expected ',' or ']' at " + at);
            }
        }

        private static string ParseString(string s, ref int at)
        {
            if (s.Length <= at || '"' != s[at])
            {
                throw new ArgumentException("expected a string at " + at);
            }
            at++;
            var out_ = new StringBuilder();
            while (at < s.Length)
            {
                var c = s[at];
                at++;
                if ('"' == c)
                {
                    return out_.ToString();
                }
                if ('\\' != c)
                {
                    out_.Append(c);
                    continue;
                }
                if (s.Length <= at)
                {
                    throw new ArgumentException("unexpected end in string");
                }
                var e = s[at];
                at++;
                switch (e)
                {
                    case '"': out_.Append('"'); break;
                    case '\\': out_.Append('\\'); break;
                    case '/': out_.Append('/'); break;
                    case 'b': out_.Append('\b'); break;
                    case 'f': out_.Append('\f'); break;
                    case 'n': out_.Append('\n'); break;
                    case 'r': out_.Append('\r'); break;
                    case 't': out_.Append('\t'); break;
                    case 'u':
                        // A csharp char IS a UTF-16 code unit, so a
                        // surrogate pair needs no joining: appending both
                        // halves is the string.
                        if (s.Length < at + 4)
                        {
                            throw new ArgumentException("bad \\u escape at " + at);
                        }
                        out_.Append((char)Convert.ToInt32(s.Substring(at, 4), 16));
                        at += 4;
                        break;
                    default:
                        throw new ArgumentException("bad escape at " + at);
                }
            }
            throw new ArgumentException("unterminated string");
        }

        private static object ParseNumber(string s, ref int at)
        {
            var start = at;
            if (at < s.Length && '-' == s[at])
            {
                at++;
            }
            while (at < s.Length
                   && (char.IsDigit(s[at]) || '.' == s[at] || 'e' == s[at] || 'E' == s[at]
                       || '+' == s[at] || '-' == s[at]))
            {
                at++;
            }
            var text = s.Substring(start, at - start);
            // INVARIANT culture: a machine whose decimal separator is a
            // comma would otherwise parse `1.5` as 15.
            if (!double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var n))
            {
                throw new ArgumentException("bad number " + text + " at " + start);
            }
            return n;
        }
    }
}
