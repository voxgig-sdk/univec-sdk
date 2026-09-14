// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (csharp/src/Json.cs)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// Just enough JSON for sekreto.
//
// System.Text.Json is part of the base class library, not a third-party
// package, so this is a thin adapter onto it rather than a parser of its
// own: JSON in, plain Dictionary/List/string/double/bool/null out - and
// back again for the CLI's line of output.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Text.Json;

namespace Voxgig.Sekreto
{
    public static class Json
    {
        /// <summary>Parse JSON text, answering null for anything unreadable.</summary>
        public static object Parse(string text)
        {
            return TryParse(text, out object value) ? value : null;
        }

        /// <summary>
        /// Parse JSON text, answering false when the text is not JSON at all
        /// - which a null answer from Parse cannot say, since JSON `null`
        /// parses to the same thing.
        /// </summary>
        public static bool TryParse(string text, out object value)
        {
            value = null;

            if (string.IsNullOrEmpty(text))
            {
                return false;
            }

            try
            {
                using var doc = JsonDocument.Parse(text);
                value = Convert(doc.RootElement);
                return true;
            }
            catch (JsonException)
            {
                return false;
            }
        }

        private static object Convert(JsonElement element)
        {
            switch (element.ValueKind)
            {
                case JsonValueKind.Object:
                    var map = new Dictionary<string, object>();
                    foreach (JsonProperty entry in element.EnumerateObject())
                    {
                        map[entry.Name] = Convert(entry.Value);
                    }
                    return map;

                case JsonValueKind.Array:
                    var list = new List<object>();
                    foreach (JsonElement entry in element.EnumerateArray())
                    {
                        list.Add(Convert(entry));
                    }
                    return list;

                case JsonValueKind.String:
                    return element.GetString();

                case JsonValueKind.Number:
                    return element.GetDouble();

                case JsonValueKind.True:
                    return true;

                case JsonValueKind.False:
                    return false;

                default:
                    return null;
            }
        }

        /// <summary>Render a value as compact JSON.</summary>
        public static string Stringify(object value)
        {
            var out_ = new StringBuilder();
            Write(value, out_);
            return out_.ToString();
        }

        private static void Write(object value, StringBuilder out_)
        {
            switch (value)
            {
                case null:
                    out_.Append("null");
                    return;

                case string text:
                    Quote(text, out_);
                    return;

                case bool flag:
                    out_.Append(flag ? "true" : "false");
                    return;

                case double number:
                    // 5.0 prints as 5, matching every other port.
                    out_.Append(number == Math.Truncate(number) && Math.Abs(number) < 1e15
                        ? ((long)number).ToString(CultureInfo.InvariantCulture)
                        : number.ToString("R", CultureInfo.InvariantCulture));
                    return;

                case int number:
                    out_.Append(number.ToString(CultureInfo.InvariantCulture));
                    return;

                case Dictionary<string, object> map:
                    out_.Append('{');
                    bool firstentry = true;
                    foreach (var entry in map)
                    {
                        if (!firstentry)
                        {
                            out_.Append(',');
                        }
                        firstentry = false;
                        Quote(entry.Key, out_);
                        out_.Append(':');
                        Write(entry.Value, out_);
                    }
                    out_.Append('}');
                    return;

                case List<object> list:
                    out_.Append('[');
                    bool firstitem = true;
                    foreach (object item in list)
                    {
                        if (!firstitem)
                        {
                            out_.Append(',');
                        }
                        firstitem = false;
                        Write(item, out_);
                    }
                    out_.Append(']');
                    return;

                default:
                    Quote(System.Convert.ToString(value, CultureInfo.InvariantCulture), out_);
                    return;
            }
        }

        private static void Quote(string text, StringBuilder out_)
        {
            out_.Append('"');

            foreach (char head in text)
            {
                switch (head)
                {
                    case '"': out_.Append("\\\""); break;
                    case '\\': out_.Append("\\\\"); break;
                    case '\n': out_.Append("\\n"); break;
                    case '\r': out_.Append("\\r"); break;
                    case '\t': out_.Append("\\t"); break;
                    default:
                        if (0x20 > head)
                        {
                            out_.Append("\\u").Append(((int)head).ToString("x4"));
                        }
                        else
                        {
                            out_.Append(head);
                        }
                        break;
                }
            }

            out_.Append('"');
        }
    }
}
